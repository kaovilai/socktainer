import ContainerResource
import Vapor

struct ContainerTopQuery: Content {
    let ps_args: String?
}

struct ContainerTopRoute: RouteCollection {
    let client: ClientContainerProtocol
    let runner: ClientContainerCommandRunner

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/containers/{id}/top", use: ContainerTopRoute.handler(client: client, runner: runner))
    }
}

extension ContainerTopRoute {
    static func handler(client: ClientContainerProtocol, runner: ClientContainerCommandRunner) -> @Sendable (Request) async throws -> RESTContainerTop {
        { req in
            let query = try req.query.decode(ContainerTopQuery.self)
            let container = try await runningContainer(req, client: client)
            let command = ContainerTop.dockerCommand(psArgs: query.ps_args)
            let output = try await runPS(command, in: container, runner: runner, logger: req.logger)
            let top = try parse { try ContainerTop.parseDockerOutput(output, command: command) }
            // moby logs a `top` event for every successful top; podman has no such event.
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                await broadcaster.broadcast(DockerEvent.containerEvent("top", container: container))
            }
            return top
        }
    }

    /// The container named by the `id` route parameter, which must be running.
    static func runningContainer(_ req: Request, client: ClientContainerProtocol) async throws -> ContainerSnapshot {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Container ID is required")
        }
        let container: ContainerSnapshot?
        do {
            container = try await client.getContainer(id: id)
        } catch ClientContainerError.ambiguousId(let reference, let matches) {
            throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
        }
        guard let container else {
            throw Abort(.notFound, reason: "No such container: \(id)")
        }
        guard container.status == .running else {
            throw Abort(.conflict, reason: "container \(id) is not running")
        }
        return container
    }

    /// Runs `ps` in the container and returns what it printed, failing like Docker does when
    /// `ps` cannot run or exits non-zero.
    static func runPS(_ command: [String], in container: ContainerSnapshot, runner: ClientContainerCommandRunner, logger: Logger) async throws -> String {
        let output: ContainerCommandOutput
        do {
            output = try await runner.run(container: container, command: command, asRoot: true)
        } catch {
            logger.warning("top: \(command.joined(separator: " ")) did not run in \(container.id): \(error)")
            // Apple Container reports a missing executable as "failed to find target executable".
            let cause = "\(error)".contains("failed to find target executable") ? "ps: executable file not found in the container" : "\(error)"
            throw Abort(.internalServerError, reason: "\(cause) (top runs ps inside the container, so the image must provide ps)")
        }
        guard output.exitCode == 0 else {
            let detail = (output.stderr.isEmpty ? output.stdout : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Abort(.internalServerError, reason: "Error running ps: exit status \(output.exitCode): \(detail)")
        }
        return output.stdout
    }

    static func parse(_ body: () throws -> RESTContainerTop) throws -> RESTContainerTop {
        do {
            return try body()
        } catch ContainerTopError.noPIDColumn {
            throw Abort(.internalServerError, reason: "Couldn't find PID field in ps output")
        } catch ContainerTopError.noOutput {
            throw Abort(.internalServerError, reason: "ps printed no output")
        }
    }
}
