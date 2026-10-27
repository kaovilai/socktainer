import Vapor

struct LibpodExecStartRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        // Podman posts `{"Detach":true}` without a Content-Type.
        let handler = LibpodAdapter.preparing(ExecRoute.startExec(client: client), Self.prepare)
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/exec/{id}/start", use: handler)
    }

    @Sendable static func prepare(_ req: Request) -> Request {
        LibpodAdapter.defaultToJSON(req)
        req.storage[ExecStartUsesSessionTtyKey.self] = true
        return req
    }
}

/// podman's exec start runs the session with the terminal setting it was created with and
/// ignores the start body's `Tty`, which the podman client fills from its own stdin (`false`
/// whenever that is not a terminal, as in a script) even for `exec -t`. Honouring it there
/// would run `exec -t` without a pty and frame output the client reads raw.
struct ExecStartUsesSessionTtyKey: StorageKey {
    typealias Value = Bool
}
