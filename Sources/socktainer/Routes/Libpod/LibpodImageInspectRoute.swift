import Vapor

struct LibpodImageInspectRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/images/{name:.*}/json", use: ImageInspectRoute.handler(client: client))
    }
}
