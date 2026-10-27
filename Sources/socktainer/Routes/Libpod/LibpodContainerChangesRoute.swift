import Vapor

/// `podman diff <container>`: podman's endpoint answers with the same `{Path, Kind}` list.
struct LibpodContainerChangesRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let changesClient: ClientContainerChangesProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/libpod/containers/{id}/changes",
            use: ContainerChangesRoute.handler(containerClient: containerClient, changesClient: changesClient))
    }
}
