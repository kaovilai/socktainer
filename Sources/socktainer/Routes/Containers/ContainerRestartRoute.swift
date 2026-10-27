import ContainerResource
import Vapor

struct ContainerRestartRoute: RouteCollection {
    let client: ClientContainerProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/containers/{id}/restart", use: ContainerRestartRoute.handler(client: client))
    }
}

struct ContainerRestartQuery: Content {
    let signal: String?
    let t: Int?/// Number of seconds to wait before killing the container
}

extension ContainerRestartRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> HTTPStatus {
        { req in
            guard let id = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }

            let query = try req.query.decode(ContainerRestartQuery.self)
            let signal = query.signal
            let timeout = query.t

            let snapshot = try? await client.getContainer(id: id)

            if let nativeId = snapshot?.id {
                await ContainerRestartState.shared.reset(id: nativeId)
            }

            let broadcaster = req.application.storage[EventBroadcasterKey.self]!
            // moby's restart stops a running container through containerStop, which logs `kill`
            // before the signal goes out. The reset above retired the run's exit observer, so the
            // `die` and `stop` that follow are logged here once the stop is done.
            let wasRunning = snapshot?.status == .running
            let exitGeneration = await ContainerExitCodeStore.shared.generation(id: snapshot?.id ?? id)
            if let snapshot, wasRunning {
                await broadcaster.broadcast(Self.killEvent(container: snapshot, signal: signal))
            }

            do {
                try await client.restart(id: id, signal: signal, timeout: timeout)
            } catch ClientContainerError.notFound {
                throw Abort(.notFound, reason: "No such container: \(id)")
            } catch ClientContainerError.ambiguousId(let reference, let matches) {
                let matchList = matches.joined(separator: ", ")
                throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matchList)")
            } catch let conflict as ExclusiveVolumeInUseError {
                throw conflict
            } catch {
                req.logger.error("Failed to restart container \(id): \(error)")
                throw Abort(.internalServerError, reason: "Failed to restart container: \(error)")
            }

            // The restart started a new run of the container. A `die` is claimed per run and the
            // claim is never handed back, so without opening one here the restarted container's
            // exit would find the previous run's claim held and go unreported.
            let runEpoch = await DieEventOwnership.shared.beginRestartedRun(id: snapshot?.id ?? id)

            let exitCode = await ContainerExitCodeStore.shared.get(id: snapshot?.id ?? id, recordedAfter: exitGeneration)
            for event in Self.completionEvents(id: id, snapshot: snapshot, wasRunning: wasRunning, exitCode: exitCode) {
                await broadcaster.broadcast(event)
            }

            // Re-arm restart-policy enforcement the same way /start does — otherwise a
            // manually-restarted container has no observer watching its next exit.
            let dnsServer = req.application.storage[SocktainerDNSServerKey.self]
            let healthManager = req.application.storage[HealthCheckManagerKey.self]
            let restartedSnapshot = await ContainerStartRoute.performPostStartSetup(
                id: id, client: client, dnsServer: dnsServer, healthManager: healthManager, logger: req.logger
            )
            if let snap = restartedSnapshot {
                let eventId = DockerContainerID.hexId(for: snap)
                let restartPolicy = RestartPolicyManager.decode(from: snap.configuration.labels)
                let generation = await ContainerRestartState.shared.currentGeneration(id: snap.id)
                await ContainerStartRoute.armRestartObserver(
                    nativeId: snap.id,
                    eventId: eventId,
                    image: snap.configuration.image.reference,
                    name: snap.id,
                    labels: LabelNormalization.restore(snap.configuration.labels),
                    ip: ContainerStartRoute.dnsAttachmentIP(in: snap),
                    refreshCache: true,
                    restartPolicy: restartPolicy,
                    generation: generation,
                    runEpoch: runEpoch,
                    broadcaster: broadcaster,
                    dnsServer: dnsServer,
                    healthManager: healthManager,
                    client: client,
                    logger: req.logger
                )
            }

            return .noContent
        }
    }

    /// The `kill` moby's containerStop logs for the stop signal (SIGTERM by default) as a number.
    static func killEvent(container: ContainerSnapshot, signal: String?) -> DockerEvent {
        let signalNumber = (try? parseSignal(signal ?? "SIGTERM")) ?? SIGTERM
        return DockerEvent.containerEvent("kill", container: container, extraAttributes: ["signal": String(signalNumber)])
    }

    /// The events moby logs once a restart's stop and start are done: `die` (with the exit code
    /// when it is known) and `stop` for a container that was running, then `start` and `restart`.
    static func completionEvents(id: String, snapshot: ContainerSnapshot?, wasRunning: Bool, exitCode: Int32?) -> [DockerEvent] {
        // Carry the canonical 64-char Docker id, not the raw request
        // reference (name or short id), so clients can correlate these
        // events with start/kill/die (same pattern as those routes).
        func event(_ status: String, extra: [String: String] = [:]) -> DockerEvent {
            DockerEvent.simpleEvent(
                id: snapshot.map { DockerContainerID.hexId(for: $0) } ?? id,
                type: "container",
                status: status,
                image: snapshot?.configuration.image.reference ?? "",
                name: snapshot?.id ?? id,
                labels: LabelNormalization.restore(snapshot?.configuration.labels ?? [:]),
                extraAttributes: extra
            )
        }
        var events: [DockerEvent] = []
        if wasRunning {
            events.append(event("die", extra: exitCode.map { ["exitCode": String($0)] } ?? [:]))
            events.append(event("stop"))
        }
        events.append(event("start"))
        events.append(event("restart"))
        return events
    }
}
