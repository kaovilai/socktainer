import ContainerResource
import Vapor

struct ContainerPauseRoute: RouteCollection {
    let client: ClientContainerProtocol
    let pauser: ContainerPauseService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/pause", use: ContainerPauseRoute.handler(client: client, pauser: pauser, pause: true))
    }
}

extension ContainerPauseRoute {
    /// `pause: false` answers `/unpause`. Both answer 204, 404 for an unknown container, and 409
    /// when the container is not running or not in the state the call changes.
    static func handler(client: ClientContainerProtocol, pauser: ContainerPauseService, pause: Bool) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }
            let found: ContainerSnapshot?
            do {
                found = try await client.getContainer(id: id)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = found else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            do {
                if pause {
                    try await pauser.pause(container, logger: req.logger)
                } else {
                    try await pauser.unpause(container, logger: req.logger)
                }
            } catch ContainerPauseError.notRunning {
                throw Abort(.conflict, reason: "Container \(id) is not running")
            } catch ContainerPauseError.alreadyPaused {
                throw Abort(.conflict, reason: "Container \(id) is already paused")
            } catch ContainerPauseError.notPaused {
                throw Abort(.conflict, reason: "Container \(id) is not paused")
            } catch let error as AbortError {
                throw error
            } catch {
                req.logger.error("Failed to \(pause ? "pause" : "unpause") container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Cannot \(pause ? "pause" : "unpause") container \(id): \(error)")
            }

            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                let event = DockerEvent.simpleEvent(
                    id: DockerContainerID.hexId(for: container),
                    type: "container",
                    status: pause ? "pause" : "unpause",
                    image: container.configuration.image.reference,
                    name: container.id,
                    labels: LabelNormalization.restore(container.configuration.labels)
                )
                await broadcaster.broadcast(event)
            }
            return Response(status: .noContent)
        }
    }
}
