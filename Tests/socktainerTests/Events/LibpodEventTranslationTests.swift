import Foundation
import Testing

@testable import socktainer

private func event(_ action: String, id: String = "ctr", timeNano: UInt64, type: String = "container", attributes: [String: String] = [:]) -> DockerEvent {
    DockerEvent(
        status: action, id: id, from: "", Type: type, Action: action,
        Actor: DockerActor(ID: id, Attributes: attributes), scope: "local",
        time: Int(timeNano / 1_000_000_000), timeNano: timeNano)
}

@Suite("LibpodEventTranslation")
struct LibpodEventTranslationTests {
    @Test("Docker-only actions are renamed to podman statuses")
    func renames() {
        #expect(LibpodEventTranslation.translate(event("die", timeNano: 1, attributes: ["exitCode": "3"]))?.Action == "died")
        #expect(LibpodEventTranslation.translate(event("die", timeNano: 1, attributes: ["exitCode": "3"]))?.Actor.Attributes["containerExitCode"] == "3")
        #expect(LibpodEventTranslation.translate(event("destroy", timeNano: 1))?.Action == "remove")
        #expect(LibpodEventTranslation.translate(event("delete", timeNano: 1, type: "image"))?.Action == "remove")
        #expect(LibpodEventTranslation.translate(event("load", timeNano: 1, type: "image"))?.Action == "loadfromarchive")
        #expect(LibpodEventTranslation.translate(event("destroy", id: "v", timeNano: 1, type: "volume"))?.Action == "remove")
        #expect(LibpodEventTranslation.translate(event("exec_start: sh", timeNano: 1))?.Action == "exec")
        #expect(LibpodEventTranslation.translate(event("exec_die", timeNano: 1))?.Action == "exec_died")
    }

    @Test("health_status carries the status in HealthStatus")
    func health() {
        let translated = LibpodEventTranslation.translate(event("health_status: healthy", timeNano: 1))
        #expect(translated?.Action == "health_status")
        #expect(translated?.HealthStatus == "healthy")
    }

    @Test("actions and types podman cannot decode are dropped")
    func dropped() {
        #expect(LibpodEventTranslation.translate(event("exec_create: sh", timeNano: 1)) == nil)
        #expect(LibpodEventTranslation.translate(event("resize", timeNano: 1)) == nil)
        #expect(LibpodEventTranslation.translate(event("prune", timeNano: 1, type: "builder")) == nil)
    }

    @Test("volume events get the volume name in the name attribute")
    func volumeName() {
        #expect(LibpodEventTranslation.translate(event("create", id: "data", timeNano: 1, type: "volume"))?.Actor.Attributes["name"] == "data")
    }

    @Test("HealthStatus is omitted from JSON when nil")
    func jsonOmitsHealth() throws {
        let json = String(decoding: try JSONEncoder().encode(event("start", timeNano: 1)), as: UTF8.self)
        #expect(!json.contains("HealthStatus"))
    }
}
