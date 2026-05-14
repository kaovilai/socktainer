import Vapor

struct LibpodNetworkDeleteRoute: RouteCollection {
    let dockerRoute: NetworkDeletetRoute

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/networks/{name}", use: dockerRoute.handler)
    }
}
