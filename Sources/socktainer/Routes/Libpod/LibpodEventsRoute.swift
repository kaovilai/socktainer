import Vapor

struct LibpodEventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol

    func boot(routes: RoutesBuilder) throws {
        // Same broadcaster as /events; the libpod flavor translates actions to podman's
        // vocabulary, applies podman's filter semantics, and honours `stream=false`.
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/events", use: EventsRoute.handler(client: client, flavor: .libpod))
    }
}
