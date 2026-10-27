import Vapor

struct ContainerUnpauseRoute: RouteCollection {
    let client: ClientContainerProtocol
    let pauser: ContainerPauseService

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/unpause", use: ContainerPauseRoute.handler(client: client, pauser: pauser, pause: false))
    }
}
