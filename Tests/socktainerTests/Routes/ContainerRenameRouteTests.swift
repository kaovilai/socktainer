import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private actor RenameMock: ClientContainerProtocol {
    let failure: ClientContainerError?
    private(set) var calls: [(id: String, newName: String)] = []
    /// The container's current name, when lookups should find it; renames update it.
    private var currentName: String?

    init(failure: ClientContainerError? = nil, existing: String? = nil) {
        self.failure = failure
        self.currentName = existing
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        guard let currentName, id == currentName else { return nil }
        return try makeContainerSnapshot(nativeId: currentName, ip: "192.168.64.2", network: "default", labels: [:])
    }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func rename(id: String, newName: String) async throws {
        calls.append((id, newName))
        if let failure { throw failure }
        currentName = newName
    }
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

private func withRenameApp(
    _ mock: RenameMock, broadcaster: EventBroadcaster? = nil, _ body: (Application) async throws -> Void
) async throws {
    try await withApp(configure: { _ in }) { app in
        if let broadcaster { app.storage[EventBroadcasterKey.self] = broadcaster }
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        try app.register(collection: ContainerRenameRoute(client: mock))
        try await body(app)
    }
}

@Suite("ContainerRenameRoute")
struct ContainerRenameRouteTests {
    @Test("Renames to the requested name, accepting a leading slash")
    func renames() async throws {
        let mock = RenameMock()
        try await withRenameApp(mock) { app in
            try await app.testing().test(.POST, "/v1.51/containers/abc_web-1/rename?name=/web-1") { res async in
                #expect(res.status == .noContent)
            }
        }
        let calls = await mock.calls
        #expect(calls.count == 1)
        #expect(calls.first?.id == "abc_web-1")
        #expect(calls.first?.newName == "web-1")
    }

    @Test("A missing name is a bad request")
    func missingName() async throws {
        let mock = RenameMock()
        try await withRenameApp(mock) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web-1/rename") { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(await mock.calls.isEmpty)
    }

    @Test(
        "Client errors map to Docker status codes",
        arguments: [
            (ClientContainerError.notFound(id: "web-1"), HTTPStatus.notFound),
            (ClientContainerError.nameConflict("db-1"), HTTPStatus.conflict),
            (ClientContainerError.renameRequiresStopped(id: "web-1"), HTTPStatus.conflict),
            (ClientContainerError.invalidName("bad name"), HTTPStatus.badRequest),
        ])
    func mapsErrors(failure: ClientContainerError, status: HTTPStatus) async throws {
        try await withRenameApp(RenameMock(failure: failure)) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web-1/rename?name=db-1") { res async in
                #expect(res.status == status)
            }
        }
    }

    @Test("A rename broadcasts moby's rename event: the new name, and oldName with its leading slash")
    func broadcastsRenameEvent() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let capture = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "rename" { return event }
            return nil
        }
        try await withRenameApp(RenameMock(existing: "old-web"), broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/old-web/rename?name=new-web") { res async in
                #expect(res.status == .noContent)
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture.cancel()
        }
        let event = await capture.value
        timeout.cancel()
        #expect(event?.Type == "container")
        #expect(event?.Actor.Attributes["name"] == "new-web")
        #expect(event?.Actor.Attributes["oldName"] == "/old-web")
        #expect(event.flatMap(LibpodEventTranslation.translate)?.Action == "rename")
    }

    @Test("A failed rename broadcasts nothing")
    func failedRenameBroadcastsNothing() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let capture = Task<DockerEvent?, Never> {
            for await event in stream { return event }
            return nil
        }
        try await withRenameApp(RenameMock(failure: .nameConflict("db-1"), existing: "web-1"), broadcaster: broadcaster) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web-1/rename?name=db-1") { res async in
                #expect(res.status == .conflict)
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        capture.cancel()
        #expect(await capture.value == nil)
    }
}
