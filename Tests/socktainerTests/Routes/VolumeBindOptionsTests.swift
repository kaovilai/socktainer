import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker volume create --driver local --opt type=none --opt o=bind --opt device=/host/dir`
/// backs a volume with a host directory, shared over virtiofs so that several running containers
/// can mount it at once (an ext4 image volume attaches to one VM only).
@Suite("Local volume bind options")
struct VolumeBindOptionsTests {
    @Test("bind options are recognized from o=bind or o=rbind with a device")
    func recognized() {
        let bind = LocalBindVolume(options: ["type": "none", "o": "bind", "device": "/srv/data"])
        #expect(bind?.device == "/srv/data")
        #expect(bind?.readOnly == false)
        #expect(LocalBindVolume(options: ["o": "rbind,ro", "device": "/srv/data"])?.readOnly == true)
        #expect(LocalBindVolume(options: ["o": "bind"]) == nil)
        #expect(LocalBindVolume(options: ["size": "1G"]) == nil)
        #expect(LocalBindVolume(options: ["type": "nfs", "o": "addr=10.0.0.1", "device": ":/export"]) == nil)
    }

    @Test("options moby's local driver refuses are rejected")
    func validation() throws {
        try LocalBindVolume.validate(options: ["type": "none", "o": "bind", "device": "/srv/data"])
        try LocalBindVolume.validate(options: ["size": "1G"])
        #expect(throws: LocalBindVolumeError.missingDevice) { try LocalBindVolume.validate(options: ["o": "bind"]) }
        #expect(throws: LocalBindVolumeError.relativeDevice("data")) {
            try LocalBindVolume.validate(options: ["o": "bind", "device": "data"])
        }
        #expect(throws: LocalBindVolumeError.unsupportedType("ext4")) {
            try LocalBindVolume.validate(options: ["type": "ext4", "o": "bind", "device": "/srv/data"])
        }
    }

    @Test("a bind-backed volume mounts its host directory over virtiofs")
    func virtiofsMount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bindvol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = VolumeConfiguration(
            name: "shared", source: "/images/shared.img", options: ["type": "none", "o": "bind,ro", "device": directory.path])
        let mount = try #require(try ContainerCreateRoute.bindVolumeMount(volume, destination: "/data", options: []))
        #expect(mount.isVirtiofs)
        #expect(mount.source == directory.path)
        #expect(mount.destination == "/data")
        #expect(mount.options.contains("ro"))

        let plain = VolumeConfiguration(name: "plain", source: "/images/plain.img")
        #expect(try ContainerCreateRoute.bindVolumeMount(plain, destination: "/data", options: []) == nil)
    }

    @Test("the container label maps mount destinations back to bind-backed volume names")
    func containerLabel() throws {
        let label = try #require(LocalBindVolume.label(volumeNames: ["/data": "shared", "/cache": "cache"]))
        #expect(LocalBindVolume.volumeNames(labels: [LocalBindVolume.containerLabel: label]) == ["/data": "shared", "/cache": "cache"])
        #expect(LocalBindVolume.label(volumeNames: [:]) == nil)
        #expect(LocalBindVolume.volumeNames(labels: [:]).isEmpty)
        #expect(LocalBindVolume.volumeNames(labels: [LocalBindVolume.containerLabel: "not json"]).isEmpty)
    }

    @Test("containers mounting a bind-backed volume are found through their label")
    func inUse() throws {
        let label = try #require(LocalBindVolume.label(volumeNames: ["/data": "shared"]))
        let user = try makeContainerSnapshot(
            nativeId: "user", ip: "192.168.64.2", network: "default", labels: [LocalBindVolume.containerLabel: label], status: .running)
        let other = try makeContainerSnapshot(nativeId: "other", ip: "192.168.64.3", network: "default", labels: [:], status: .running)
        #expect(LocalBindVolume.containers(using: "shared", in: [user, other]) == [DockerContainerID.hexId(for: user)])
        #expect(LocalBindVolume.containers(using: "unused", in: [user, other]).isEmpty)
    }

    @Test("mounting a bind-backed volume whose directory is gone fails")
    func missingDevice() {
        let volume = VolumeConfiguration(
            name: "gone", source: "/images/gone.img", options: ["type": "none", "o": "bind", "device": "/nonexistent-\(UUID().uuidString)"])
        #expect(throws: Abort.self) { try ContainerCreateRoute.bindVolumeMount(volume, destination: "/data", options: []) }
    }

    @Test("a bind-backed volume reports its host directory as Mountpoint")
    func inspectMountpoint() {
        let bind = VolumeConfiguration(name: "shared", source: "/images/shared.img", options: ["type": "none", "o": "bind", "device": "/srv/data"])
        let converted = ClientVolumeService.convert(bind)
        #expect(converted.Mountpoint == "/srv/data")
        #expect(converted.Options == ["type": "none", "o": "bind", "device": "/srv/data"])
        #expect(ClientVolumeService.convert(VolumeConfiguration(name: "plain", source: "/images/plain.img")).Mountpoint == "/images/plain.img")
    }

    @Test("volume create refuses bind options without an absolute device before creating anything")
    func createRejects() async throws {
        try await withApp(configure: { app in
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: VolumeCreateRoute(client: ClientVolumeService()))
            for body in [
                #"{"Name":"v","DriverOpts":{"type":"none","o":"bind"}}"#,
                #"{"Name":"v","DriverOpts":{"type":"none","o":"bind","device":"relative/dir"}}"#,
            ] {
                try await app.testing().test(
                    .POST, "/v1.51/volumes/create", headers: ["Content-Type": "application/json"], body: ByteBuffer(string: body)
                ) { res async in
                    #expect(res.status == .badRequest)
                }
            }
        }
    }
}
