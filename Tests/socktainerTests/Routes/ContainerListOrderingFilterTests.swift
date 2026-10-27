import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// `docker ps --filter before=<ref>` / `since=<ref>` with a reference that names no
/// container fails with 404 "No such container" in Docker, rather than listing nothing.
@Suite("Container list before/since references")
struct ContainerListOrderingFilterTests {

    private static func snapshots() throws -> [ContainerSnapshot] {
        [
            try makeContainerSnapshot(nativeId: "web-1", ip: "192.168.64.20", network: "default", labels: [:], status: .running),
            try makeContainerSnapshot(nativeId: "db-1", ip: "192.168.64.21", network: "default", labels: [:], status: .stopped),
        ]
    }

    @Test("a reference naming a container, by exact name or ID prefix, resolves")
    func knownReferencesResolve() throws {
        let all = try Self.snapshots()
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["before": ["web-1"]], among: all) == nil)
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["since": ["db-1"]], among: all) == nil)
        let hexPrefix = String(DockerContainerID.hexId(for: all[0]).prefix(12))
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["since": [hexPrefix]], among: all) == nil)
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["status": ["running"]], among: all) == nil)
    }

    @Test("an unknown before or since reference is reported")
    func unknownReferenceIsReported() throws {
        let all = try Self.snapshots()
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["before": ["nope"]], among: all) == "nope")
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["since": ["web-1", "gone"]], among: all) == "gone")
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["since": ["web-1"]], among: []) == "web-1")
        // A name prefix names nothing: Docker answers "No such container: db".
        #expect(ClientContainerService.unresolvedOrderingReference(in: ["since": ["db"]], among: all) == "db")
    }

    @Test("an unknown reference answers 404 on the Docker and libpod list routes")
    func unknownReferenceOverHTTP() async throws {
        try await withApp(configure: { app in app.middleware.use(DockerErrorMiddleware(), at: .beginning) }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            let client = OrderingFilterClient(containers: try Self.snapshots())
            try app.register(collection: ContainerListRoute(client: client))
            try app.register(collection: LibpodContainerListRoute(client: client))

            let filters = #"{"before":["nope"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(filters)") { res async throws in
                #expect(res.status == .notFound)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["message"] as? String == "No such container: nope")
            }
            try await app.testing().test(.GET, "/v1.51/libpod/containers/json?all=true&filters=\(filters)") { res async throws in
                #expect(res.status == .notFound)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])
                #expect(body["message"] as? String == "no such container: nope")
                #expect(body["response"] as? Int == 404)
            }

            let known = #"{"since":["web-1"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            try await app.testing().test(.GET, "/v1.51/containers/json?all=1&filters=\(known)") { res async throws in
                #expect(res.status == .ok)
            }
        }
    }
}

/// Lists like `ClientContainerService.list` does, minus the Apple Container round trip.
private struct OrderingFilterClient: ClientContainerProtocol {
    let containers: [ContainerSnapshot]

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] {
        if let missing = ClientContainerService.unresolvedOrderingReference(in: filters, among: containers) {
            throw ClientContainerError.notFound(id: missing)
        }
        return ClientContainerService.listing(containers, showAll: showAll, filters: filters)
    }
    func getContainer(id: String) async throws -> ContainerSnapshot? { containers.first { $0.id == id } }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
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
