import ContainerResource
import Vapor

struct LibpodContainerWaitRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/{id}/wait", use: LibpodContainerWaitRoute.handler(client: client))
    }

    /// One condition of podman's libpod `wait`. Real podman names the container's own lowercase
    /// statuses ("configured", "created", "running", "paused", "exited", "stopped", "removing",
    /// ...) plus "healthy"/"unhealthy", not Docker compat's `wait` vocabulary.
    enum Condition: Equatable, Sendable {
        /// Answered with the exit code, through the Docker-compat wait.
        case exit(ContainerWaitCondition)
        /// Answered with -1 once the container is in the state, as podman does.
        case state(State)
    }

    enum State: String, Equatable, Sendable {
        case running, created, paused, healthy, unhealthy
    }

    /// Poll interval for state conditions; podman's own default.
    static let statePollIntervalNs: UInt64 = 250_000_000

    /// podman's `interval` query: how often to check the condition, as a Go duration
    /// ("250ms"). Anything unparsable is a 400, as in podman; an interval under a
    /// millisecond is polled every millisecond rather than spinning.
    static func pollInterval(from req: Request) throws -> UInt64 {
        guard let raw = req.query[String.self, at: "interval"], !raw.isEmpty else { return statePollIntervalNs }
        guard let seconds = GoDuration.seconds(raw) else {
            throw Abort(.badRequest, reason: "invalid interval \"\(raw)\": time: invalid duration \"\(raw)\"")
        }
        return UInt64(max(seconds, 0.001) * 1_000_000_000)
    }

    /// Every `condition` value (repeatable, and comma-separated for good measure); podman waits for
    /// the container to stop when none is given.
    static func conditions(from req: Request) throws -> [Condition] {
        let items = URLComponents(string: "?" + (req.url.query ?? ""))?.queryItems ?? []
        let raw = items.filter { $0.name == "condition" }.compactMap(\.value)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        guard !raw.isEmpty else { return [.exit(.notRunning)] }
        return try raw.map(mapLibpodCondition)
    }

    /// "removing" (in-progress removal) maps to Docker-compat's `removed`, since this daemon has no
    /// distinct in-progress-removal state to block on; "configured" is a never-started container.
    static func mapLibpodCondition(_ raw: String) throws -> Condition {
        switch raw {
        case "stopped", "exited":
            return .exit(.notRunning)
        case "removed", "removing":
            return .exit(.removed)
        case "running":
            return .state(.running)
        case "created", "configured":
            return .state(.created)
        case "paused":
            return .state(.paused)
        case "healthy":
            return .state(.healthy)
        case "unhealthy":
            return .state(.unhealthy)
        case "stopping", "unknown":
            throw Abort(.notImplemented, reason: "waiting for condition '\(raw)' is not supported")
        default:
            throw Abort(.badRequest, reason: "Invalid wait condition: \(raw)")
        }
    }

    /// Waits until any of the conditions holds — podman ORs them — and answers with the bare
    /// integer podman's binding decodes, not Docker's `{"StatusCode": N}` object: the exit code
    /// for an exit condition, -1 for a state. The Docker-compat wait also resolves a container
    /// that already exited before `/wait` arrived (the usual order for `podman run`).
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            guard let reference = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            let conditions = try conditions(from: req)
            let interval = try pollInterval(from: req)
            let container = try await ContainerWaitRoute.preflight(client: client, reference: reference)
            let nativeId = container.id
            if conditions.contains(where: { $0 == .state(.healthy) || $0 == .state(.unhealthy) }),
                container.configuration.labels[HealthCheckManager.healthcheckLabel] == nil
            {
                throw Abort(.internalServerError, reason: "cannot use a health condition: container \(nativeId) has no healthcheck")
            }

            var pending: [(ContainerWaitCondition, ContainerWaitRoute.PendingWait)] = []
            for case .exit(let condition) in conditions where !pending.contains(where: { $0.0 == condition }) {
                pending.append((condition, await ContainerWaitRoute.PendingWait.begin(condition: condition, nativeId: nativeId, app: req.application)))
            }
            let states = Set(conditions.compactMap { if case .state(let state) = $0 { state } else { nil } })
            let app = req.application

            let code: Int64 = await withTaskGroup(of: Int64?.self) { group in
                for (condition, begun) in pending {
                    group.addTask {
                        await ContainerWaitRoute.waitResult(
                            condition: condition, containerId: nativeId, nativeId: nativeId, client: client, app: app, pending: begun
                        ).StatusCode
                    }
                }
                if !states.isEmpty {
                    group.addTask { await stateReached(states, nativeId: nativeId, client: client, app: app, intervalNs: interval) }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return -1
            }
            return try LibpodAdapter.jsonResponse(code)
        }
    }

    /// Polls until the container is in one of `states` (-1), it is gone (-1, as podman reports a
    /// container that vanished), or the task is cancelled (nil).
    static func stateReached(
        _ states: Set<State>, nativeId: String, client: ClientContainerProtocol, app: Application,
        intervalNs: UInt64 = statePollIntervalNs
    ) async -> Int64? {
        while !Task.isCancelled {
            do {
                guard let container = try await client.getContainer(id: nativeId) else { return -1 }
                // A paused container still runs as far as Apple Container is concerned; podman calls it paused.
                let paused = ContainerPauseState.shared.isPaused(container)
                if states.contains(.running), container.status == .running, !paused { return -1 }
                if states.contains(.paused), paused { return -1 }
                if states.contains(.created), container.isNeverStarted { return -1 }
                if states.contains(.healthy) || states.contains(.unhealthy),
                    let status = await app.storage[HealthCheckManagerKey.self]?.currentHealth(for: nativeId)?.Status,
                    let health = State(rawValue: status), states.contains(health)
                {
                    return -1
                }
            } catch {
                // A failed lookup is not a removal; poll again.
            }
            do {
                try await Task.sleep(nanoseconds: intervalNs)
            } catch {
                return nil
            }
        }
        return nil
    }
}
