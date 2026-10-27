import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// A default named volume is an ext4 disk image; a second running container that attaches it
/// boots on its own copy of the filesystem, diverging from (and risking corruption of) the
/// first. Starting such a container must fail with a 409 naming the volume and its holder;
/// bind-option volumes (virtiofs shares) stay shareable.
@Suite("ExclusiveVolumeUse — disk-image volumes are not shared between running containers")
struct ExclusiveVolumeUseTests {

    @Test("a disk-image volume mounted by another running container is a conflict")
    func runningHolderConflicts() {
        let holder = exclusiveVolumeSnapshot(id: "db1", status: .running, mounts: [diskVolume("data")])
        let starting = exclusiveVolumeSnapshot(id: "db2", status: .stopped, mounts: [diskVolume("data")])
        let conflict = ExclusiveVolumeUse.conflict(for: starting, among: [holder, starting])
        #expect(conflict == ExclusiveVolumeInUseError(volume: "data", holder: "db1"))
        #expect(conflict?.status == .conflict)
        #expect(conflict?.reason.contains("volume \"data\" is in use by running container db1") == true)
        #expect(conflict?.reason.contains("--opt type=none --opt o=bind --opt device=<dir>") == true)
    }

    @Test("a stopped holder, another volume, or the container itself is no conflict")
    func noConflict() {
        let starting = exclusiveVolumeSnapshot(id: "db2", status: .stopped, mounts: [diskVolume("data")])
        let stoppedHolder = exclusiveVolumeSnapshot(id: "db1", status: .stopped, mounts: [diskVolume("data")])
        let otherVolume = exclusiveVolumeSnapshot(id: "db3", status: .running, mounts: [diskVolume("other")])
        #expect(ExclusiveVolumeUse.conflict(for: starting, among: [stoppedHolder, otherVolume, starting]) == nil)
    }

    @Test("bind-option volumes are virtiofs shares and stay shareable")
    func virtiofsSharesAreExempt() {
        let share = Filesystem.virtiofs(source: "/tmp/shared", destination: "/data", options: [])
        let holder = exclusiveVolumeSnapshot(id: "a", status: .running, mounts: [share])
        let starting = exclusiveVolumeSnapshot(id: "b", status: .stopped, mounts: [share])
        #expect(ExclusiveVolumeUse.diskImageVolumes(of: starting).isEmpty)
        #expect(ExclusiveVolumeUse.conflict(for: starting, among: [holder, starting]) == nil)
    }

    @Test(
        "docker and libpod start answer the conflict with 409, not 500",
        arguments: ["/v1.51/containers/db2/start", "/v5.0.0/libpod/containers/db2/start"])
    func startRouteReturnsConflict(path: String) async throws {
        let mock = ConflictingStartMock(
            snapshot: exclusiveVolumeSnapshot(id: "db2", status: .stopped, mounts: [diskVolume("data")]))
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: ContainerStartRoute(client: mock))
            try app.register(collection: LibpodContainerStartRoute(client: mock))

            try await app.testing().test(.POST, path) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("is in use by running container db1"))
            }
        }
    }
}

private func diskVolume(_ name: String) -> Filesystem {
    Filesystem.volume(
        name: name, format: "ext4", source: "/tmp/volumes/\(name)/volume.img", destination: "/data", options: [])
}

private func exclusiveVolumeSnapshot(id: String, status: RuntimeStatus, mounts: [Filesystem]) -> ContainerSnapshot {
    let proc = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [],
        workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0)
    )
    let img = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0)
    )
    var config = ContainerConfiguration(id: id, image: img, process: proc)
    config.mounts = mounts
    return ContainerSnapshot(configuration: config, status: status, networks: [])
}

/// Stands in for ClientContainerService.start finding the volume held by `db1`.
private struct ConflictingStartMock: ClientContainerProtocol {
    let snapshot: ContainerSnapshot

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [snapshot] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {
        throw ExclusiveVolumeInUseError(volume: "data", holder: "db1")
    }
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
