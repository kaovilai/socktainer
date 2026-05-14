import Vapor

struct LibpodBuildRoute: RouteCollection {
    let client: ClientContainerProtocol
    let builderClient: ClientBuilderProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/build", use: BuildRoute.handler(client: client, builderClient: builderClient))
    }
}
