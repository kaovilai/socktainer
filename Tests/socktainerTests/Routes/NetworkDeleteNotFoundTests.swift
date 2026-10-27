import ContainerResource
import ContainerizationError
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Apple's network client reports a missing network as `notFound: "no network for id …"`, which the
/// route's old text match ("not found") missed, so a missing network answered 500 instead of 404.
@Suite("NetworkDeleteRoute — missing network")
struct NetworkDeleteNotFoundTests {
    @Test("deleting a network that does not exist is a 404")
    func missingNetworkIs404() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: NetworkDeleteRoute(client: MissingNetworkClient()))

            try await app.testing().test(.DELETE, "/v1.51/networks/nosuch") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }
}

private struct MissingNetworkClient: ClientNetworkProtocol {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func delete(id: String, logger: Logger) async throws {
        throw ContainerizationError(.notFound, message: "no network for id \(id)")
    }
    func create(name: String, labels: [String: String], ipv4Subnet: String?, mode: NetworkMode, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
}
