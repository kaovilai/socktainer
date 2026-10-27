import ContainerResource
import Vapor

struct EventBroadcasterKey: StorageKey {
    typealias Value = EventBroadcaster
}

struct DockerActor: Codable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEvent: Codable {
    let status: String
    let id: String
    let from: String
    let `Type`: String
    let Action: String
    let Actor: DockerActor
    let scope: String
    let time: Int
    let timeNano: UInt64
    /// Podman's `entities.Event.HealthStatus`; only set on translated libpod
    /// `health_status` events and omitted from the JSON otherwise.
    var HealthStatus: String? = nil
}

extension DockerEvent {
    /// General constructor mirroring moby's `EventsService.Log(action, type, Actor{ID, Attributes})`.
    /// The deprecated top-level fields are derived exactly as moby does for backward compatibility:
    /// `id` = Actor.ID, `status` = action, `from` = Attributes["image"] (empty when absent).
    /// Use this for image/network/volume/prune events, whose attribute sets differ from containers
    /// (e.g. no forced `image`/`name` keys).
    static func make(
        type: String,
        action: String,
        actorID: String,
        attributes: [String: String]
    ) -> DockerEvent {
        let now = Date()
        let timeSeconds = Int(now.timeIntervalSince1970)
        let timeNano = UInt64(now.timeIntervalSince1970 * 1_000_000_000)

        return DockerEvent(
            status: action,
            id: actorID,
            from: attributes["image"] ?? "",
            Type: type,
            Action: action,
            Actor: DockerActor(ID: actorID, Attributes: attributes),
            scope: "local",
            time: timeSeconds,
            timeNano: timeNano
        )
    }

    /// Container-shaped event: moby's `LogContainerEventWithAttributes` always injects
    /// `image` and `name` attributes alongside the container labels. Keep using this for
    /// `Type: "container"` events only. `extraAttributes` carries action-specific keys moby
    /// adds on top (e.g. `signal` on `kill`, `exitCode` on `die`/`exec_die`); they override
    /// any same-named label.
    static func simpleEvent(
        id: String,
        type: String,
        status: String,
        image: String = "",
        name: String = "",
        labels: [String: String] = [:],
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        var attributes = labels
        attributes["image"] = image
        attributes["name"] = name.isEmpty ? id : name
        for (key, value) in extraAttributes { attributes[key] = value }
        return make(type: type, action: status, actorID: id, attributes: attributes)
    }

    /// Container-shaped event derived from a snapshot: canonical 64-char Docker id,
    /// image reference, native name, and restored labels — the fields every
    /// container lifecycle event site otherwise re-derives by hand.
    static func containerEvent(
        _ action: String,
        container: ContainerSnapshot,
        extraAttributes: [String: String] = [:]
    ) -> DockerEvent {
        simpleEvent(
            id: DockerContainerID.hexId(for: container),
            type: "container",
            status: action,
            image: container.configuration.image.reference,
            name: container.id,
            labels: LabelNormalization.restore(container.configuration.labels),
            extraAttributes: extraAttributes
        )
    }
}

/// Fixed-capacity FIFO of the most recent events (moby keeps the last 256 in
/// `daemon/events.Events.events`). Appending past capacity drops the oldest entry.
struct EventHistory: Sendable {
    let capacity: Int
    private var storage: [DockerEvent] = []
    private var head = 0  // index of the oldest element once storage is full

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    mutating func append(_ event: DockerEvent) {
        guard capacity > 0 else { return }
        if storage.count < capacity {
            storage.append(event)
        } else {
            storage[head] = event
            head = (head + 1) % capacity
        }
    }

    /// Buffered events, oldest first.
    var events: [DockerEvent] {
        Array(storage[head...] + storage[..<head])
    }

    var count: Int { storage.count }
}

/// A live subscription plus the buffered events that were already broadcast when it
/// was registered. Both are captured in a single actor turn, so every event lands in
/// exactly one of them — no gap and no duplicate between replay and live delivery.
struct EventSubscription: Sendable {
    let id: UUID
    let history: [DockerEvent]
    let stream: AsyncStream<DockerEvent>
}

actor EventBroadcaster {
    /// Default number of past events kept for `since`/`until` replay.
    /// Override with `SOCKTAINER_EVENTS_HISTORY` (0 disables replay).
    static let defaultHistoryLimit = 1000

    static func configuredHistoryLimit(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let raw = environment["SOCKTAINER_EVENTS_HISTORY"], let value = Int(raw), value >= 0 else {
            return defaultHistoryLimit
        }
        return value
    }

    private var continuations: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]
    /// When each (actor id, action) of container and image events was last broadcast, so `ExternalEventWatcher`
    /// can skip transitions socktainer's own routes already reported.
    private var lastEmitted: [String: Date] = [:]
    private var history: EventHistory

    init(historyLimit: Int = EventBroadcaster.configuredHistoryLimit()) {
        history = EventHistory(capacity: historyLimit)
    }

    func stream() -> AsyncStream<DockerEvent> {
        register(id: UUID())
    }

    /// Registers a live listener and snapshots the history buffer in the same actor
    /// turn (see `EventSubscription`).
    func subscribe() -> EventSubscription {
        let id = UUID()
        let stream = register(id: id)
        return EventSubscription(id: id, history: history.events, stream: stream)
    }

    /// Ends a subscription's stream (e.g. when its `until` deadline passes).
    func finish(id: UUID) {
        continuations.removeValue(forKey: id)?.finish()
    }

    /// Buffered events, oldest first.
    func recentEvents() -> [DockerEvent] {
        history.events
    }

    func broadcast(_ event: DockerEvent) {
        history.append(event)
        if event.Type == "container" || event.Type == "image" {
            let now = Date()
            lastEmitted = lastEmitted.filter { now.timeIntervalSince($0.value) < 60 }
            lastEmitted["\(event.Actor.ID)/\(event.Action)"] = now
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func register(id: UUID) -> AsyncStream<DockerEvent> {
        // Register the continuation synchronously, before returning the stream. The
        // previous implementation deferred registration to `Task { addContinuation }`,
        // leaving a window where the stream existed but was not yet in `continuations`
        // — any event broadcast in that window was silently dropped for this listener
        // (e.g. a container's start event firing right after `docker events` connects).
        // `makeStream` lets us register inside the actor-isolated method with no race.
        let (stream, continuation) = AsyncStream.makeStream(of: DockerEvent.self)
        continuations[id] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.removeContinuation(id: id) }
        }
        return stream
    }

    /// Open `stream()` subscriptions; one drops once its stream is released.
    var subscriberCount: Int { continuations.count }

    func emittedRecently(id: String, action: String, within interval: TimeInterval) -> Bool {
        guard let last = lastEmitted["\(id)/\(action)"] else { return false }
        return Date().timeIntervalSince(last) < interval
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
