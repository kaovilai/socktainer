import Foundation
import Testing

@testable import socktainer

private func event(
    type: String = "container",
    action: String,
    id: String = "abc123def456",
    attributes: [String: String] = [:],
    timeNano: UInt64 = 1_000_000_000_000_000_000
) -> DockerEvent {
    DockerEvent(
        status: action, id: id, from: attributes["image"] ?? "", Type: type, Action: action,
        Actor: DockerActor(ID: id, Attributes: attributes), scope: "local",
        time: Int(timeNano / 1_000_000_000), timeNano: timeNano)
}

private func dockerFilter(_ json: String) throws -> EventFilter {
    try EventFilter.parse(json, flavor: .docker)
}

private func libpodFilter(_ json: String) throws -> EventFilter {
    try EventFilter.parse(json, flavor: .libpod)
}

@Suite("EventFilter — parsing")
struct EventFilterParsingTests {
    @Test("absent or empty filters match everything")
    func emptyMatchesAll() throws {
        #expect(try EventFilter.parse(nil, flavor: .docker).isEmpty)
        #expect(try EventFilter.parse("", flavor: .docker).isEmpty)
        #expect(try dockerFilter("{}").matches(event(action: "start")))
    }

    @Test("legacy map form {key:{value:true}} is accepted")
    func legacyForm() throws {
        let filter = try dockerFilter(#"{"event":{"start":true,"stop":false}}"#)
        #expect(filter.values["event"] == ["start"])
    }

    @Test("malformed JSON is rejected")
    func malformed() {
        #expect(throws: EventFilter.ParseError.self) { try dockerFilter("not json") }
    }

    @Test("libpod rejects keys podman does not know, Docker does not")
    func unknownKeys() throws {
        #expect(throws: EventFilter.ParseError.invalidKey("network")) { try libpodFilter(#"{"network":["n"]}"#) }
        _ = try dockerFilter(#"{"network":["n"],"daemon":["d"]}"#)
    }
}

@Suite("EventFilter — Docker semantics (moby daemon/events/filter.go)")
struct EventFilterDockerTests {
    @Test("event filter: exact match, multiple values OR")
    func eventExact() throws {
        let filter = try dockerFilter(#"{"event":["start","die"]}"#)
        #expect(filter.matches(event(action: "start")))
        #expect(filter.matches(event(action: "die")))
        #expect(!filter.matches(event(action: "stop")))
        #expect(!filter.matches(event(action: "start-ish")))
    }

    @Test("event=health_status / exec_start switch to prefix matching")
    func eventFuzzy() throws {
        let filter = try dockerFilter(#"{"event":["health_status"]}"#)
        #expect(filter.matches(event(action: "health_status: healthy")))
        let exec = try dockerFilter(#"{"event":["exec_start"]}"#)
        #expect(exec.matches(event(action: "exec_start: sh -c true")))
        #expect(!exec.matches(event(action: "exec_die")))
    }

    @Test("different keys AND together")
    func keysAnd() throws {
        let filter = try dockerFilter(#"{"event":["start"],"container":["web"]}"#)
        #expect(filter.matches(event(action: "start", attributes: ["name": "web"])))
        #expect(!filter.matches(event(action: "start", attributes: ["name": "db"])))
        #expect(!filter.matches(event(action: "stop", attributes: ["name": "web"])))
    }

    @Test("container filter: prefix on ID or name")
    func containerFuzzy() throws {
        #expect(try dockerFilter(#"{"container":["abc1"]}"#).matches(event(action: "start", attributes: ["name": "x"])))
        #expect(try dockerFilter(#"{"container":["we"]}"#).matches(event(action: "start", attributes: ["name": "web"])))
        #expect(!(try dockerFilter(#"{"container":["zzz"]}"#).matches(event(action: "start", attributes: ["name": "web"]))))
    }

    @Test("type filter excludes other event types")
    func typeFilter() throws {
        let filter = try dockerFilter(#"{"type":["network"]}"#)
        #expect(filter.matches(event(type: "network", action: "create")))
        #expect(!filter.matches(event(action: "create")))
    }

    @Test("image filter matches container events by image attribute and image events by id/name, tag stripped")
    func imageFilter() throws {
        let filter = try dockerFilter(#"{"image":["alpine"]}"#)
        #expect(filter.matches(event(action: "start", attributes: ["image": "docker.io/library/alpine:latest"])))
        #expect(filter.matches(event(type: "image", action: "pull", id: "alpine:3.20", attributes: ["name": "alpine:3.20"])))
        #expect(!filter.matches(event(action: "start", attributes: ["image": "nginx:latest"])))
    }

    @Test("label filter: key and key=value, all must match")
    func labelFilter() throws {
        let attrs = ["com.example.app": "web", "tier": "front", "name": "c"]
        #expect(try dockerFilter(#"{"label":["tier"]}"#).matches(event(action: "start", attributes: attrs)))
        #expect(try dockerFilter(#"{"label":["tier=front","com.example.app=web"]}"#).matches(event(action: "start", attributes: attrs)))
        #expect(!(try dockerFilter(#"{"label":["tier=back"]}"#).matches(event(action: "start", attributes: attrs))))
        #expect(!(try dockerFilter(#"{"label":["tier","missing"]}"#).matches(event(action: "start", attributes: attrs))))
    }

    @Test("volume / network filters match on actor ID")
    func volumeNetwork() throws {
        #expect(try dockerFilter(#"{"volume":["data"]}"#).matches(event(type: "volume", action: "create", id: "data")))
        #expect(!(try dockerFilter(#"{"volume":["data"]}"#).matches(event(type: "volume", action: "create", id: "logs"))))
        #expect(try dockerFilter(#"{"network":["net-a"]}"#).matches(event(type: "network", action: "create", id: "net-abc", attributes: ["name": "mynet"])))
    }

    @Test("stripTag mirrors reference.FamiliarName")
    func stripTag() {
        #expect(EventFilter.stripTag("docker.io/library/alpine:latest") == "alpine")
        #expect(EventFilter.stripTag("ghcr.io/org/app:1.0") == "ghcr.io/org/app")
        #expect(EventFilter.stripTag("localhost:5000/app") == "localhost:5000/app")
        #expect(EventFilter.stripTag("alpine@sha256:abc") == "alpine")
    }
}

@Suite("EventFilter — libpod semantics (podman libpod/events/filters.go)")
struct EventFilterLibpodTests {
    @Test("event=die matches podman's died status")
    func dieAlias() throws {
        let filter = try libpodFilter(#"{"event":["die"]}"#)
        #expect(filter.matches(event(action: "died")))
        #expect(!filter.matches(event(action: "start")))
    }

    @Test("container filter only matches container events (name exact or ID prefix)")
    func containerOnly() throws {
        let filter = try libpodFilter(#"{"container":["web"]}"#)
        #expect(filter.matches(event(action: "start", attributes: ["name": "web"])))
        #expect(!filter.matches(event(action: "start", attributes: ["name": "web2"])), "podman matches the name exactly")
        #expect(!filter.matches(event(type: "network", action: "create", attributes: ["name": "web"])))
        #expect(try libpodFilter(#"{"container":["abc1"]}"#).matches(event(action: "start")))
    }

    @Test("keys are case-insensitive and AND together")
    func caseInsensitive() throws {
        let filter = try libpodFilter(#"{"EVENT":["start"],"type":["container"]}"#)
        #expect(filter.matches(event(action: "start")))
        #expect(!filter.matches(event(type: "image", action: "start")))
    }

    @Test("volume filter matches name prefix")
    func volumePrefix() throws {
        let filter = try libpodFilter(#"{"volume":["da"]}"#)
        #expect(filter.matches(event(type: "volume", action: "create", id: "data", attributes: ["name": "data"])))
        #expect(!filter.matches(event(action: "create", attributes: ["name": "data"])))
    }
}
