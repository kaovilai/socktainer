import Vapor

/// `podman top`: podman sends its format descriptors (`user,pid,args`) as `ps_args`, repeated or
/// comma-separated, and no `ps_args` at all for its defaults. Anything that is not a descriptor
/// (`podman top ctr -ef`) is handed to `ps` as arguments, as podman does.
struct LibpodContainerTopRoute: RouteCollection {
    let client: ClientContainerProtocol
    let runner: ClientContainerCommandRunner

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/top", use: LibpodContainerTopRoute.handler(client: client, runner: runner))
    }

    static func handler(client: ClientContainerProtocol, runner: ClientContainerCommandRunner) -> @Sendable (Request) async throws -> RESTContainerTop {
        { req in
            let container = try await ContainerTopRoute.runningContainer(req, client: client)
            let descriptors = ContainerTop.libpodDescriptors(allQueryValues(named: "ps_args", from: req.url.query))
            guard let plan = ContainerTop.libpodPlan(descriptors: descriptors) else {
                let command = ["ps"] + descriptors
                let output = try await ContainerTopRoute.runPS(command, in: container, runner: runner, logger: req.logger)
                return try ContainerTopRoute.parse { try ContainerTop.parseDockerOutput(output, command: command) }
            }
            let output = try await ContainerTopRoute.runPS(plan.command, in: container, runner: runner, logger: req.logger)
            return try ContainerTopRoute.parse { try ContainerTop.parseLibpodOutput(output, plan: plan) }
        }
    }
}
