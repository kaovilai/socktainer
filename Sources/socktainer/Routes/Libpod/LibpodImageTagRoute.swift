import Vapor

struct LibpodImageTagRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/{name:.*}/tag", use: ImageTagRoute.handler)
    }
}
