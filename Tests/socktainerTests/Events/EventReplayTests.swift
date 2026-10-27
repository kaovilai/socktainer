import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private func event(_ action: String, id: String = "ctr", timeNano: UInt64, type: String = "container", attributes: [String: String] = [:]) -> DockerEvent {
    DockerEvent(
        status: action, id: id, from: "", Type: type, Action: action,
        Actor: DockerActor(ID: id, Attributes: attributes), scope: "local",
        time: Int(timeNano / 1_000_000_000), timeNano: timeNano)
}

private let second: UInt64 = 1_000_000_000

@Suite("EventHistory — ring buffer")
struct EventHistoryTests {
    @Test("keeps insertion order below capacity")
    func belowCapacity() {
        var history = EventHistory(capacity: 3)
        history.append(event("a", timeNano: 1))
        history.append(event("b", timeNano: 2))
        #expect(history.events.map(\.Action) == ["a", "b"])
    }

    @Test("drops the oldest entries past capacity, oldest first")
    func wrapsAround() {
        var history = EventHistory(capacity: 3)
        for (i, action) in ["a", "b", "c", "d", "e"].enumerated() {
            history.append(event(action, timeNano: UInt64(i)))
        }
        #expect(history.count == 3)
        #expect(history.events.map(\.Action) == ["c", "d", "e"])
    }

    @Test("capacity 0 keeps nothing")
    func zeroCapacity() {
        var history = EventHistory(capacity: 0)
        history.append(event("a", timeNano: 1))
        #expect(history.events.isEmpty)
    }

    @Test("SOCKTAINER_EVENTS_HISTORY overrides the default limit")
    func configuredLimit() {
        #expect(EventBroadcaster.configuredHistoryLimit(environment: [:]) == EventBroadcaster.defaultHistoryLimit)
        #expect(EventBroadcaster.configuredHistoryLimit(environment: ["SOCKTAINER_EVENTS_HISTORY": "5"]) == 5)
        #expect(EventBroadcaster.configuredHistoryLimit(environment: ["SOCKTAINER_EVENTS_HISTORY": "-1"]) == EventBroadcaster.defaultHistoryLimit)
    }

    @Test("broadcaster records broadcast events and bounds them")
    func broadcasterRecords() async {
        let broadcaster = EventBroadcaster(historyLimit: 2)
        for action in ["create", "start", "die"] {
            await broadcaster.broadcast(event(action, timeNano: 1))
        }
        #expect(await broadcaster.recentEvents().map(\.Action) == ["start", "die"])
    }

    @Test("subscribe splits events between history and stream with no gap or duplicate")
    func subscribeNoDup() async {
        let broadcaster = EventBroadcaster(historyLimit: 10)
        await broadcaster.broadcast(event("create", timeNano: 1))
        let subscription = await broadcaster.subscribe()
        await broadcaster.broadcast(event("start", timeNano: 2))
        await broadcaster.finish(id: subscription.id)

        var live: [String] = []
        for await e in subscription.stream { live.append(e.Action) }
        #expect(subscription.history.map(\.Action) == ["create"])
        #expect(live == ["start"])
    }
}

@Suite("EventTimeWindow — since/until")
struct EventTimeWindowTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Docker CLI timestamps: seconds and seconds.nanos")
    func unixTimestamps() throws {
        let window = try EventTimeWindow.parse(since: "1699999700.5", until: "1700000000.000000001", now: now)
        #expect(window.since == 1_699_999_700_500_000_000)
        #expect(window.until == 1_700_000_000_000_000_001)
        #expect(try EventTimeWindow.parse(since: "1700000000", until: nil, now: now).since == 1_700_000_000 * Int64(second))
        // Empty values are ignored, like an absent parameter.
        #expect(try EventTimeWindow.parse(since: "", until: "", now: now) == EventTimeWindow())
    }

    @Test("podman durations: since is in the past, until in the future")
    func durations() throws {
        let window = try EventTimeWindow.parse(since: "5m", until: "10s", now: now)
        #expect(window.since == 1_700_000_000_000_000_000 - 300 * Int64(second))
        #expect(window.until == 1_700_000_000_000_000_000 + 10 * Int64(second))
        #expect(EventTimeWindow.parseGoDuration("1h30m") == 5_400 * Int64(second))
        #expect(EventTimeWindow.parseGoDuration("1.5s") == 1_500_000_000)
        #expect(EventTimeWindow.parseGoDuration("250ms") == 250_000_000)
        #expect(EventTimeWindow.parseGoDuration("0") == 0)
        #expect(EventTimeWindow.parseGoDuration("5x") == nil)
    }

    @Test("RFC 3339 and date layouts")
    func layouts() throws {
        let window = try EventTimeWindow.parse(since: "2023-11-14T22:13:20Z", until: nil, now: now)
        #expect(window.since == 1_700_000_000 * Int64(second))
        #expect(try EventTimeWindow.parse(since: "2023-11-14", until: nil, now: now).since == 1_699_920_000 * Int64(second))
    }

    @Test("invalid values and since > until are rejected")
    func invalid() {
        #expect(throws: EventTimeWindow.ParseError.self) { try EventTimeWindow.parse(since: "yesterday", until: nil, now: now) }
        #expect(throws: EventTimeWindow.ParseError.self) { try EventTimeWindow.parse(since: nil, until: "garbage", now: now) }
        #expect(throws: EventTimeWindow.ParseError.sinceAfterUntil) {
            try EventTimeWindow.parse(since: "1700000010", until: "1700000000", now: now)
        }
    }

    @Test("onlyPast / remainingNanos follow moby: past until ends after replay")
    func pastFuture() throws {
        let past = try EventTimeWindow.parse(since: nil, until: "1699999999", now: now)
        #expect(past.onlyPast(now: now))
        #expect(past.remainingNanos(now: now) == nil)
        let future = try EventTimeWindow.parse(since: nil, until: "1700000002", now: now)
        #expect(!future.onlyPast(now: now))
        #expect(future.remainingNanos(now: now) == 2 * second)
        #expect(!EventTimeWindow().wantsReplay)
    }

    @Test("contains is inclusive on both ends")
    func contains() throws {
        let window = EventTimeWindow(since: 10, until: 20)
        #expect(window.contains(event("a", timeNano: 10)))
        #expect(window.contains(event("a", timeNano: 20)))
        #expect(!window.contains(event("a", timeNano: 9)))
        #expect(!window.contains(event("a", timeNano: 21)))
    }
}

@Suite("EventsRoute — history replay")
struct EventsRouteReplayTests {
    /// Fills a broadcaster with events at fixed past times, then runs a request that
    /// terminates (until in the past / stream=false) and returns the decoded body.
    private func run(_ path: String, events: [DockerEvent]) async throws -> (HTTPStatus, [DockerEvent]) {
        let broadcaster = EventBroadcaster(historyLimit: 100)
        for e in events { await broadcaster.broadcast(e) }
        var status: HTTPStatus = .ok
        var decoded: [DockerEvent] = []
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = broadcaster
            try app.register(collection: EventsRoute(client: ClientHealthCheckService()))
            try app.register(collection: LibpodEventsRoute(client: ClientHealthCheckService()))
            try await app.testing().test(.GET, path) { res async in
                status = res.status
                decoded = res.body.string.split(separator: "\n").compactMap {
                    try? JSONDecoder().decode(DockerEvent.self, from: Data($0.utf8))
                }
            }
        }
        return (status, decoded)
    }

    private let base: UInt64 = 1_700_000_000 * 1_000_000_000

    private var sample: [DockerEvent] {
        [
            event("create", id: "c1", timeNano: base + 1 * second, attributes: ["name": "web"]),
            event("start", id: "c1", timeNano: base + 2 * second, attributes: ["name": "web"]),
            event("start", id: "c2", timeNano: base + 3 * second, attributes: ["name": "db"]),
            event("die", id: "c1", timeNano: base + 4 * second, attributes: ["name": "web", "exitCode": "0"]),
            event("destroy", id: "c1", timeNano: base + 5 * second, attributes: ["name": "web"]),
        ]
    }

    @Test("docker: since/until window replays only matching past events, in order, then ends")
    func dockerWindow() async throws {
        let (status, events) = try await run("/v1.51/events?since=1700000002&until=1700000004", events: sample)
        #expect(status == .ok)
        #expect(events.map(\.Action) == ["start", "start", "die"])
    }

    @Test("docker: filters apply to replayed events")
    func dockerFiltered() async throws {
        let filters = #"{"event":["start"],"container":["web"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let (_, events) = try await run("/v1.51/events?since=0&until=1700000010&filters=\(filters)", events: sample)
        #expect(events.map(\.id) == ["c1"])
        #expect(events.map(\.Action) == ["start"])
    }

    @Test("docker: since after until is a 400")
    func dockerBadWindow() async throws {
        let (status, _) = try await run("/v1.51/events?since=1700000005&until=1700000001", events: sample)
        #expect(status == .badRequest)
    }

    @Test("libpod: stream=false replays the buffer in podman's vocabulary and ends")
    func libpodStreamFalse() async throws {
        let (status, events) = try await run("/v5.0.0/libpod/events?stream=false", events: sample)
        #expect(status == .ok)
        #expect(events.map(\.Action) == ["create", "start", "start", "died", "remove"])
        #expect(events[3].Actor.Attributes["containerExitCode"] == "0")
    }

    @Test("libpod: event=die filter matches the translated died event")
    func libpodDieFilter() async throws {
        let filters = #"{"event":["die"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let (_, events) = try await run("/v5.0.0/libpod/events?stream=false&filters=\(filters)", events: sample)
        #expect(events.map(\.Action) == ["died"])
    }

    @Test("libpod: unknown filter key is a 400")
    func libpodBadKey() async throws {
        let filters = #"{"bogus":["x"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let (status, _) = try await run("/v5.0.0/libpod/events?stream=false&filters=\(filters)", events: sample)
        #expect(status == .badRequest)
    }
}
