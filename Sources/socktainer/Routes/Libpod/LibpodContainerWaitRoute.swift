import Vapor

struct LibpodContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/wait", use: LibpodContainerWaitRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let containerId = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let conditionString = req.query["condition"] as String?
            let condition: ContainerWaitCondition

            if let conditionString = conditionString {
                condition = ContainerWaitCondition(rawValue: conditionString) ?? ContainerWaitCondition.default
            } else {
                condition = ContainerWaitCondition.default
            }

            do {
                let waitResponse = try await client.wait(id: containerId, condition: condition)
                return try await waitResponse.StatusCode.encodeResponse(for: req)
            } catch ClientContainerError.notFound(let id) {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch {
                throw Abort(.internalServerError, reason: "Failed to wait for container: \(error)")
            }
        }
    }
}
