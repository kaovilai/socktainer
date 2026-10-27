import ContainerAPIClient
import ContainerResource
import Vapor

/// One entry of `GET /containers/{id}/changes` (moby's `container.FilesystemChange`).
struct RESTContainerChange: Content, Equatable {
    let Path: String
    let Kind: Int
}

/// `docker diff`: the container's filesystem changes relative to its image (`RootfsDiff`).
struct ContainerChangesRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let changesClient: ClientContainerChangesProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/containers/{id}/changes",
            use: ContainerChangesRoute.handler(containerClient: containerClient, changesClient: changesClient))
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        changesClient: ClientContainerChangesProtocol
    ) -> @Sendable (Request) async throws -> [RESTContainerChange] {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let resolved: ContainerSnapshot?
            do {
                resolved = try await containerClient.getContainer(id: reference)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = resolved else {
                throw Abort(.notFound, reason: "No such container: \(reference)")
            }

            do {
                return try await changesClient.changes(container: container).map { RESTContainerChange(Path: $0.path, Kind: $0.kind.rawValue) }
            } catch let error as ClientArchiveError {
                if case .rootfsNotFound = error {
                    throw Abort(.notFound, reason: error.localizedDescription)
                }
                throw Abort(.internalServerError, reason: error.localizedDescription)
            }
        }
    }
}
