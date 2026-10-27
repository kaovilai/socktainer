import Vapor

struct LibpodContainerPauseRoute: RouteCollection {
    let client: ClientContainerProtocol
    let pauser: ContainerPauseService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/pause", use: ContainerPauseRoute.handler(client: client, pauser: pauser, pause: true))
    }
}
