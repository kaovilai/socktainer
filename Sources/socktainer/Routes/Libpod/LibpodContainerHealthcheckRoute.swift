import ContainerResource
import Foundation
import Vapor

/// podman's `HealthCheckResults`: what `podman healthcheck run` decodes.
struct LibpodHealthCheckResults: Content {
    let Status: String
    let FailingStreak: Int
    let Log: [HealthLogEntry]
}

/// `podman healthcheck run`: runs the container's configured healthcheck now and records the
/// result, so `State.Health` in inspect (Docker-compat and libpod) reflects it. `Status` is the
/// outcome of this run (`healthy`, `starting` inside the start period, or `unhealthy`), which
/// podman prints and turns into its exit code.
struct LibpodContainerHealthcheckRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/{id}/healthcheck", use: Self.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> LibpodHealthCheckResults {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Container ID is required")
            }
            let found: ContainerSnapshot?
            do {
                found = try await client.getContainer(id: id)
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
            }
            guard let container = found else {
                throw Abort(.notFound, reason: "No such container: \(id)")
            }
            guard let config = healthcheck(of: container) else {
                throw Abort(.conflict, reason: "container \(id) has no defined healthcheck")
            }
            guard container.status == .running else {
                throw Abort(.conflict, reason: "container \(id) is not running")
            }
            guard let manager = req.application.storage[HealthCheckManagerKey.self],
                let result = await manager.runNow(containerId: container.id, config: config)
            else {
                throw Abort(.internalServerError, reason: "healthchecks are not available")
            }
            return LibpodHealthCheckResults(Status: result.status, FailingStreak: result.health.FailingStreak, Log: result.health.Log)
        }
    }

    /// The container's healthcheck, as the create route recorded it, unless disabled.
    static func healthcheck(of container: ContainerSnapshot) -> HealthcheckConfig? {
        guard let json = container.configuration.labels[HealthCheckManager.healthcheckLabel],
            let config = try? JSONDecoder().decode(HealthcheckConfig.self, from: Data(json.utf8)),
            HealthCheckManager.parseTest(config.Test) != nil
        else { return nil }
        return config
    }
}
