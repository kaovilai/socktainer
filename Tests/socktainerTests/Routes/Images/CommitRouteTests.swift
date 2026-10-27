import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("CommitRoute")
struct CommitRouteTests {

    @Test("commits the exported rootfs with the composed config and answers 201 with the image id")
    func commitsContainer() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"],"ExposedPorts":{"80/tcp":{}}}}"#)
        let archive = CommitArchiveClient()
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)

        try await withCommitApp(snapshot: snapshot, archive: archive, images: images) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web&repo=io-committed&tag=v1&comment=hello&author=me&changes=ENV%20A%3D1&changes=LABEL%20k%3Dv"
            ) { res async throws in
                #expect(res.status == .created)
                let body = try JSONDecoder().decode(RESTCommitResponse.self, from: Data(buffer: res.body))
                #expect(body.Id == "sha256:committed")
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.repo == "io-committed")
        #expect(call.tag == "v1")
        #expect(call.comment == "hello")
        #expect(call.author == "me")
        #expect(call.tarContents == "rootfs-of-web")
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["/bin/sh"])
        #expect(config["Env"] as? [String] == ["A=1"])
        #expect(config["Labels"] as? [String: String] == ["k": "v"])
        #expect((config["ExposedPorts"] as? [String: Any])?.keys.sorted() == ["80/tcp"])
        #expect(await archive.exportedIds() == ["web"])
    }

    @Test("commits only the container's changes as a layer over the manifest its rootfs came from")
    func commitsChangeLayer() async throws {
        let images = RecordingCommitClient(
            baseConfig: #"{"config":{"Cmd":["/bin/retagged"]}}"#,
            layeredBaseConfig: #"{"config":{"Cmd":["/bin/sh"]},"rootfs":{"type":"layers","diff_ids":["sha256:aa"]}}"#)
        let archive = CommitArchiveClient(changeLayerBase: "sha256:base")
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)

        try await withCommitApp(snapshot: snapshot, archive: archive, images: images) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&repo=io-layered") { res async throws in
                #expect(res.status == .created)
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.tarContents == "changes-of-web")
        #expect(call.baseManifestDigest == "sha256:base")
        // The config comes from the exact manifest the rootfs was cloned from, not from
        // whatever the image reference points at now.
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["/bin/sh"])
        #expect(await archive.exportedIds().isEmpty)
        #expect(await archive.leftoverChangeLayers().isEmpty)
    }

    @Test("falls back to a squashed commit when the base image's layers are no longer in the store")
    func squashesWithoutBaseLayers() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"]}}"#)
        let archive = CommitArchiveClient(changeLayerBase: "sha256:gone")
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)

        try await withCommitApp(snapshot: snapshot, archive: archive, images: images) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&repo=io-squashed") { res async throws in
                #expect(res.status == .created)
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.tarContents == "rootfs-of-web")
        #expect(call.baseManifestDigest == nil)
        #expect(await archive.exportedIds() == ["web"])
        #expect(await archive.leftoverChangeLayers().isEmpty)
    }

    @Test("a commit broadcasts moby's container commit event with the comment, image id and reference")
    func broadcastsCommitEvent() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let capture = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "commit" { return event }
            return nil
        }
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        try await withCommitApp(
            snapshot: snapshot, archive: CommitArchiveClient(), images: RecordingCommitClient(baseConfig: #"{"config":{}}"#),
            broadcaster: broadcaster
        ) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&repo=io-committed&comment=snap") { res async in
                #expect(res.status == .created)
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture.cancel()
        }
        let event = await capture.value
        timeout.cancel()
        #expect(event?.Type == "container")
        #expect(event?.Actor.Attributes["name"] == "web")
        #expect(event?.Actor.Attributes["comment"] == "snap")
        #expect(event?.Actor.Attributes["imageID"] == "sha256:committed")
        #expect(event?.Actor.Attributes["imageRef"] == "io-committed:latest")
        #expect(event.flatMap(LibpodEventTranslation.translate)?.Action == "commit")
    }

    @Test("an untagged commit's event has an empty imageRef")
    func untaggedCommitEvent() throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])
        let event = CommitRoute.commitEvent(container: snapshot, imageId: "sha256:x", repo: nil, tag: nil, comment: nil)
        #expect(event.Actor.Attributes["imageRef"] == "")
        #expect(event.Actor.Attributes["comment"] == "")
    }

    @Test("a body config overrides the container's command")
    func bodyConfigOverrides() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"]}}"#)
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"Cmd":["cat","/data"]}"#)
                }
            ) { res async in
                #expect(res.status == .created)
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.repo == nil)
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["cat", "/data"])
    }

    @Test("an unknown container is a 404 and nothing is committed")
    func unknownContainer() async throws {
        let images = RecordingCommitClient(baseConfig: "{}")
        try await withCommitApp(snapshot: nil, archive: CommitArchiveClient(), images: images) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=ghost") { res async in
                #expect(res.status == .notFound)
            }
        }
        #expect(await images.lastCall() == nil)
    }

    @Test("a missing container parameter is a 400")
    func missingContainer() async throws {
        try await withCommitApp(snapshot: nil, archive: CommitArchiveClient(), images: RecordingCommitClient(baseConfig: "{}")) { app in
            try await app.testing().test(.POST, "/v1.51/commit") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an invalid change is a 400")
    func invalidChange() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])
        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: RecordingCommitClient(baseConfig: "{}")) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&changes=FROM%20alpine") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("libpod commit answers podman's stream protocol with the bare hex id")
    func libpodStreamsId() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"]}}"#, digest: "sha256:" + String(repeating: "ab", count: 32))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images, libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/commit?container=web&repo=io-img&tag=latest&stream=true&changes=CMD%3D/bin/true") { res async throws in
                #expect(res.status == .ok)
                let line = try JSONDecoder().decode([String: String].self, from: Data(res.body.string.split(separator: "\n")[0].utf8))
                #expect(line["stream"] == String(repeating: "ab", count: 32) + "\n")
            }
        }
        let call = try #require(await images.lastCall())
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["/bin/sh", "-c", "/bin/true"])
    }

    @Test("libpod commit without stream answers an IDResponse")
    func libpodPlainId() async throws {
        let images = RecordingCommitClient(baseConfig: "{}", digest: "sha256:" + String(repeating: "cd", count: 32))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images, libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/commit?container=web") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTCommitResponse.self, from: Data(buffer: res.body))
                #expect(body.Id == String(repeating: "cd", count: 32))
            }
        }
    }
}

// MARK: - Helpers

private func withCommitApp(
    snapshot: ContainerSnapshot?,
    archive: CommitArchiveClient,
    images: RecordingCommitClient,
    libpod: Bool = false,
    broadcaster: EventBroadcaster? = nil,
    test: @escaping (Application) async throws -> Void
) async throws {
    let client: ClientContainerProtocol = snapshot.map { StaticSnapshotClientMock(snapshot: $0) } ?? NoContainerClient()
    try await withApp(configure: { _ in }) { app in
        if let broadcaster { app.storage[EventBroadcasterKey.self] = broadcaster }
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
        if libpod {
            try app.register(collection: LibpodCommitRoute(containerClient: client, archiveClient: archive, imageClient: images))
        } else {
            try app.register(collection: CommitRoute(containerClient: client, archiveClient: archive, imageClient: images))
        }
        try await test(app)
    }
}

private actor RecordingCommitClient: ClientImageCommitProtocol {
    struct Call: Sendable {
        let repo: String?
        let tag: String?
        let comment: String?
        let author: String?
        let configJSON: Data
        let tarContents: String
        let baseManifestDigest: String?
    }

    private let baseConfig: Data
    private let digest: String
    /// The config of the manifest a change layer applies to; nil when its layers are missing.
    private let layeredBaseConfig: Data?
    private var calls: [Call] = []

    init(baseConfig: String, digest: String = "sha256:committed", layeredBaseConfig: String? = nil) {
        self.baseConfig = Data(baseConfig.utf8)
        self.digest = digest
        self.layeredBaseConfig = layeredBaseConfig.map { Data($0.utf8) }
    }

    func lastCall() -> Call? { calls.last }

    func commitImage(
        tarPath: URL, repo: String?, tag: String?, comment: String?, author: String?, configJSON: Data, base: CommitBase?,
        platform: Platform, appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        let contents = try String(contentsOf: tarPath, encoding: .utf8)
        calls.append(
            Call(
                repo: repo, tag: tag, comment: comment, author: author, configJSON: configJSON, tarContents: contents,
                baseManifestDigest: base?.manifestDigest))
        return (repo, digest)
    }

    func rawImageConfig(reference: String, platform: Platform, appleContainerAppSupportUrl: URL) async throws -> Data {
        baseConfig
    }

    func commitBase(manifestDigest: String, appleContainerAppSupportUrl: URL) async throws -> CommitBase {
        guard let layeredBaseConfig else {
            throw ClientImageError.notFound(id: "layer of \(manifestDigest)")
        }
        return CommitBase(
            manifestDigest: manifestDigest, manifest: Data(#"{"layers":[]}"#.utf8), config: layeredBaseConfig,
            contentRoot: appleContainerAppSupportUrl)
    }
}

private actor CommitArchiveClient: ClientArchiveProtocol {
    private var exported: [String] = []
    private var changeLayerTars: [URL] = []
    /// The manifest digest a change layer reports; nil when the image snapshot is unavailable.
    private let changeLayerBase: String?

    init(changeLayerBase: String? = nil) {
        self.changeLayerBase = changeLayerBase
    }

    /// Change layer tars the route did not delete.
    func leftoverChangeLayers() -> [URL] {
        changeLayerTars.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func exportChangeLayer(container: ContainerSnapshot) async throws -> CommitChangeLayer? {
        guard let changeLayerBase else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-layer-test-\(UUID().uuidString).tar")
        try Data("changes-of-\(container.id)".utf8).write(to: url)
        changeLayerTars.append(url)
        return CommitChangeLayer(tarPath: url, baseManifestDigest: changeLayerBase)
    }

    func exportedIds() -> [String] { exported }

    nonisolated func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func exportRootfs(container: ContainerSnapshot) async throws -> URL {
        exported.append(container.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-test-\(UUID().uuidString).tar")
        try Data("rootfs-of-\(container.id)".utf8).write(to: url)
        return url
    }
}

private struct NoContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
