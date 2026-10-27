import Foundation

/// `filters` query parameter of `GET /events` and `GET /libpod/events`.
///
/// The two APIs share the wire format (`{"key":["v1","v2"]}`, or moby's legacy
/// `{"key":{"v1":true}}`) but match differently, so each flavor mirrors its daemon:
/// - Docker: moby `daemon/events/filter.go` (`Filter.Include`).
/// - Libpod: podman `libpod/events/filters.go` (`generateEventFilter` + `applyFilters`),
///   applied to the event after it has been translated to podman's vocabulary
///   (see `LibpodEventTranslation`).
struct EventFilter: Sendable, Equatable {
    enum Flavor: Sendable {
        case docker
        case libpod
    }

    let flavor: Flavor
    /// Filter key → accepted values. Keys are kept as sent; libpod matching is
    /// case-insensitive on the key like podman's `strings.ToUpper(filter)`.
    let values: [String: [String]]

    init(flavor: Flavor, values: [String: [String]] = [:]) {
        self.flavor = flavor
        self.values = values.filter { !$0.value.isEmpty }
    }

    /// Keys podman's `generateEventFilter` understands; anything else (including
    /// `network`) is an error there.
    static let libpodKeys: Set<String> = ["container", "event", "status", "image", "artifact", "pod", "volume", "type", "label"]

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case invalidKey(String)

        var description: String {
            switch self {
            case .malformed(let raw): return "invalid filters parameter: \(raw)"
            case .invalidKey(let key): return "\(key) is an invalid filter"
            }
        }
    }

    /// Parses the raw `filters` query value. An absent or empty value matches everything.
    static func parse(_ raw: String?, flavor: Flavor) throws -> EventFilter {
        guard let raw, !raw.isEmpty else { return EventFilter(flavor: flavor) }
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ParseError.malformed(raw)
        }

        var values: [String: [String]] = [:]
        for (key, value) in object {
            if let list = value as? [String] {
                values[key] = list
            } else if let legacy = value as? [String: Any] {
                // moby's pre-1.22 form: {"event":{"start":true}}
                values[key] = legacy.compactMap { ($0.value as? Bool) == true ? $0.key : nil }.sorted()
            } else if let single = value as? String {
                values[key] = [single]
            } else {
                throw ParseError.malformed(raw)
            }
        }

        if flavor == .libpod {
            for key in values.keys where !libpodKeys.contains(key.lowercased()) {
                throw ParseError.invalidKey(key)
            }
        }
        return EventFilter(flavor: flavor, values: values)
    }

    var isEmpty: Bool { values.isEmpty }

    func matches(_ event: DockerEvent) -> Bool {
        if values.isEmpty { return true }
        switch flavor {
        case .docker: return matchesDocker(event)
        case .libpod: return matchesLibpod(event)
        }
    }

    // MARK: - Docker (moby daemon/events/filter.go)

    /// Keys moby matches with `fuzzyMatchName`: prefix match on the actor ID or the
    /// `name` attribute, regardless of the event type.
    private static let dockerNameKeys = ["daemon", "container", "plugin", "volume", "network", "node", "service", "secret", "config"]

    private func matchesDocker(_ event: DockerEvent) -> Bool {
        guard matchEventAction(event) else { return false }
        guard exactMatch("type", event.Type) else { return false }
        guard exactMatch("scope", event.scope) else { return false }
        for key in Self.dockerNameKeys {
            guard fuzzyMatch(key, event.Actor.ID) || fuzzyMatch(key, event.Actor.Attributes["name"] ?? "") else {
                return false
            }
        }
        guard matchImage(event) else { return false }
        return matchLabels(event.Actor.Attributes)
    }

    /// moby #25798: `health_status`, `exec_create` and `exec_start` carry a suffix
    /// (`health_status: healthy`, `exec_start: sh -c ...`), so a filter naming one of
    /// them switches the whole `event` key to prefix matching.
    private func matchEventAction(_ event: DockerEvent) -> Bool {
        let fuzzyActions: Set<String> = ["health_status", "exec_create", "exec_start"]
        if let wanted = values["event"], wanted.contains(where: fuzzyActions.contains) {
            return fuzzyMatch("event", event.Action)
        }
        return exactMatch("event", event.Action)
    }

    /// Image events match on actor ID / `name`; container events on the `image`
    /// attribute — both also compared with the tag stripped.
    private func matchImage(_ event: DockerEvent) -> Bool {
        guard values["image"] != nil else { return true }
        let id = event.Actor.ID
        let imageName = event.Actor.Attributes[event.Type == "image" ? "name" : "image"] ?? ""
        return exactMatch("image", id) || exactMatch("image", imageName)
            || exactMatch("image", Self.stripTag(id)) || exactMatch("image", Self.stripTag(imageName))
    }

    /// moby `filters.Args.MatchKVList`: every `key` / `key=value` filter must be satisfied.
    private func matchLabels(_ attributes: [String: String]) -> Bool {
        guard let wanted = values["label"] else { return true }
        if attributes.isEmpty { return false }
        for entry in wanted {
            let (key, value) = Self.splitKV(entry)
            guard let actual = attributes[key] else { return false }
            if let value, value != actual { return false }
        }
        return true
    }

    private func exactMatch(_ key: String, _ source: String) -> Bool {
        guard let wanted = values[key] else { return true }
        return wanted.contains(source)
    }

    private func fuzzyMatch(_ key: String, _ source: String) -> Bool {
        guard let wanted = values[key] else { return true }
        return wanted.contains { source == $0 || source.hasPrefix($0) }
    }

    /// Approximates `reference.FamiliarName(ParseNormalizedNamed(ref))`: drop the
    /// digest/tag and the implicit `docker.io/` and `library/` prefixes.
    static func stripTag(_ reference: String) -> String {
        var name = reference
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            name = String(name[..<colon])
        }
        for prefix in ["docker.io/", "index.docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        if name.hasPrefix("library/"), name.split(separator: "/").count == 2 {
            name = String(name.dropFirst("library/".count))
        }
        return name
    }

    // MARK: - Libpod (podman libpod/events/filters.go)

    /// Different keys AND together; values of one key OR together.
    private func matchesLibpod(_ event: DockerEvent) -> Bool {
        for (key, wanted) in values {
            guard wanted.contains(where: { libpodMatch(key: key.lowercased(), value: $0, event: event) }) else {
                return false
            }
        }
        return true
    }

    private func libpodMatch(key: String, value: String, event: DockerEvent) -> Bool {
        let name = event.Actor.Attributes["name"] ?? ""
        switch key {
        case "container", "image", "artifact", "pod":
            guard event.Type == key else { return false }
            return name == value || event.Actor.ID.hasPrefix(value)
        case "volume":
            guard event.Type == "volume" else { return false }
            return name.hasPrefix(value) || event.Actor.ID.hasPrefix(value)
        case "event", "status":
            // podman maps the Docker spelling "die" onto its own "died".
            return event.Action == (value == "die" ? "died" : value)
        case "type":
            return event.Type == value
        case "label":
            let (labelKey, labelValue) = Self.splitKV(value)
            guard let actual = event.Actor.Attributes[labelKey] else { return false }
            return labelValue == nil || labelValue == actual
        default:
            return false
        }
    }

    private static func splitKV(_ entry: String) -> (String, String?) {
        guard let eq = entry.firstIndex(of: "=") else { return (entry, nil) }
        return (String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
    }
}
