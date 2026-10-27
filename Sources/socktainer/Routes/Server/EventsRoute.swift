import ContainerAPIClient
import NIOCore
import Vapor

struct EventsRoute: RouteCollection {
    let client: ClientHealthCheckProtocol
    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/events", use: EventsRoute.handler(client: client))
    }

}

extension EventsRoute {
    /// Parsed `GET /events` (or `/libpod/events`) query.
    struct Query: Sendable {
        let flavor: EventFilter.Flavor
        let filter: EventFilter
        let window: EventTimeWindow
        /// podman's `stream` parameter (default true). Docker's API has no such
        /// parameter, so it is always true on the Docker route.
        let stream: Bool

        /// moby replays its buffer only when `since` or `until` is set. podman also
        /// prints past events for `--stream=false` (read the log, then exit).
        var replaysHistory: Bool {
            window.wantsReplay || (flavor == .libpod && !stream)
        }

        /// The response ends after the replay instead of following live events.
        func onlyPast(now: Date = Date()) -> Bool {
            !stream || window.onlyPast(now: now)
        }

        /// Translates (libpod) and filters an event; nil when it must not be sent.
        func render(_ event: DockerEvent) -> DockerEvent? {
            let shaped: DockerEvent?
            switch flavor {
            case .docker: shaped = event
            case .libpod: shaped = LibpodEventTranslation.translate(event)
            }
            guard let shaped, window.contains(shaped), filter.matches(shaped) else { return nil }
            return shaped
        }

        func replay(_ history: [DockerEvent]) -> [DockerEvent] {
            guard replaysHistory else { return [] }
            return history.compactMap(render)
        }
    }

    static func parseQuery(_ req: Request, flavor: EventFilter.Flavor, now: Date = Date()) throws -> Query {
        let filter: EventFilter
        let window: EventTimeWindow
        do {
            filter = try EventFilter.parse(req.query[String.self, at: "filters"], flavor: flavor)
            window = try EventTimeWindow.parse(
                since: req.query[String.self, at: "since"],
                until: req.query[String.self, at: "until"],
                now: now)
        } catch {
            throw Abort(.badRequest, reason: "\(error)")
        }
        var stream = true
        if flavor == .libpod, let raw = req.query[String.self, at: "stream"] {
            stream = !["false", "0"].contains(raw.lowercased())
        }
        return Query(flavor: flavor, filter: filter, window: window, stream: stream)
    }

    static func handler(client: ClientHealthCheckProtocol, flavor: EventFilter.Flavor = .docker) -> @Sendable (Request) async throws -> Response {
        { req in

            guard let broadcaster = req.application.storage[EventBroadcasterKey.self] else {
                throw Abort(.internalServerError, reason: "EventBroadcaster not configured")
            }
            let query = try parseQuery(req, flavor: flavor)

            // Subscribe and snapshot the history in one actor turn: every event is
            // either in `history` or delivered on `stream`, never both.
            let subscription = await broadcaster.subscribe()
            let replayed = query.replay(subscription.history)

            // End the live stream right away (past-only request) or once `until` passes.
            let deadline: Task<Void, Never>?
            if query.onlyPast() {
                await broadcaster.finish(id: subscription.id)
                deadline = nil
            } else if let remaining = query.window.remainingNanos() {
                deadline = Task {
                    try? await Task.sleep(nanoseconds: remaining)
                    await broadcaster.finish(id: subscription.id)
                }
            } else {
                deadline = nil
            }

            let response = Response(status: .ok)
            response.headers.add(name: .contentType, value: "application/json")

            response.body = .init(asyncStream: { writer in
                defer { deadline?.cancel() }

                // Vapor queues a streaming response's head without flushing it,
                // so nothing reaches the client until the first event. Docker
                // flushes the headers right away, and clients wait on them:
                // `docker stats` (no arguments) blocks until its events
                // subscription is established. An empty write flushes the head
                // without framing a chunk, which would end the stream.
                do {
                    try await writer.write(.buffer(req.application.allocator.buffer(capacity: 0)))
                } catch {
                    // The client is already gone. End the response now, and drop
                    // the subscription by returning, instead of holding it until
                    // the next event's write fails. Writing .end rather than
                    // rethrowing: Vapor asserts if the writer is released without it.
                    await broadcaster.finish(id: subscription.id)
                    _ = try? await writer.write(.end)
                    return
                }

                func send(_ event: DockerEvent) async -> Bool {
                    guard let json = try? JSONEncoder().encode(event) else { return true }
                    var buffer = req.application.allocator.buffer(capacity: json.count + 1)
                    buffer.writeBytes(json)
                    buffer.writeString("\n")
                    do {
                        try await writer.write(.buffer(buffer))
                    } catch is IOError {
                        req.logger.debug("Client disconnected (broken pipe)")
                        return false
                    } catch let error as ChannelError where error == .ioOnClosedChannel {
                        req.logger.debug("Client disconnected (closed channel)")
                        return false
                    } catch {
                        req.logger.warning("\(event) raised '\(error)'")
                    }
                    return true
                }

                var connected = true
                for event in replayed where connected {
                    connected = await send(event)
                }
                if connected {
                    for await event in subscription.stream {
                        if let until = query.window.until, Int64(clamping: event.timeNano) > until { break }
                        guard let rendered = query.render(event) else { continue }
                        if !(await send(rendered)) { break }
                    }
                }
                await broadcaster.finish(id: subscription.id)
                _ = try? await writer.write(.end)
            })

            return response

        }
    }
}
