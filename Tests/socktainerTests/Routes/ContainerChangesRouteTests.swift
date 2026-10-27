import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("ContainerChangesRoute")
struct ContainerChangesRouteTests {

    @Test("answers moby's [{Path, Kind}] list on both the Docker and libpod paths", arguments: ["/v1.51/containers/web/changes", "/v1.51/libpod/containers/web/changes"])
    func listsChanges(path: String) async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])
        let changes = FixedChangesClient(result: .success([.init(path: "/tmp", kind: .modified), .init(path: "/tmp/x", kind: .added)]))

        try await withChangesApp(client: StaticSnapshotClientMock(snapshot: snapshot), changes: changes) { app in
            try await app.testing().test(.GET, path) { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode([RESTContainerChange].self, from: Data(buffer: res.body))
                #expect(body == [RESTContainerChange(Path: "/tmp", Kind: 0), RESTContainerChange(Path: "/tmp/x", Kind: 1)])
            }
        }
    }

    @Test("an unknown container is a 404")
    func unknownContainer() async throws {
        try await withChangesApp(client: NoSuchContainerClient(), changes: FixedChangesClient(result: .success([]))) { app in
            try await app.testing().test(.GET, "/v1.51/containers/ghost/changes") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("a booted container whose rootfs is gone is a 404, not a 500")
    func missingRootfs() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])
        let changes = FixedChangesClient(result: .failure(.rootfsNotFound(id: "web")))

        try await withChangesApp(client: StaticSnapshotClientMock(snapshot: snapshot), changes: changes) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/changes") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}

private func withChangesApp(
    client: ClientContainerProtocol,
    changes: FixedChangesClient,
    test: @escaping (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: ContainerChangesRoute(containerClient: client, changesClient: changes))
        try app.register(collection: LibpodContainerChangesRoute(containerClient: client, changesClient: changes))
        try await test(app)
    }
}

private struct FixedChangesClient: ClientContainerChangesProtocol {
    let result: Result<[RootfsDiff.Change], ClientArchiveError>

    func changes(container: ContainerSnapshot) async throws -> [RootfsDiff.Change] {
        try result.get()
    }
}

private struct NoSuchContainerClient: ClientContainerProtocol {
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
