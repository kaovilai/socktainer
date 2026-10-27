import Vapor

struct LibpodEventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol

    func boot(routes: RoutesBuilder) throws {
        // Same broadcaster as /events; the libpod flavor translates actions to podman's
        // vocabulary and applies podman's filter semantics.
        let handler = LibpodAdapter.preparing(EventsRoute.handler(client: client, flavor: .libpod)) { req in
            for name in ["since", "until"] {
                if let value = req.query[String.self, at: name], let absolute = LibpodSchema.absoluteEventTime(value) {
                    LibpodAdapter.setQuery(req, name, to: absolute)
                }
            }
            return req
        }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/events", use: handler)
    }
}
