import Vapor

/// podman resizes the terminal of `run -it`/`attach` and `exec -it` sessions through these
/// libpod paths, with the same `h`/`w` query as Docker's. Without them the requests 404, which
/// podman ignores, and the container's terminal stays at 0x0 (`stty size` fails, TUIs break).
struct LibpodResizeRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/resize", use: ContainerResizeRoute.resize(client: client))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/exec/{id}/resize", use: ExecRoute.resizeExec)
    }
}
