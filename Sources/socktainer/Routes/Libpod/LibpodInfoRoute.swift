import Vapor

struct LibpodInfoRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/info", use: InfoRoute.handler)
    }
}
