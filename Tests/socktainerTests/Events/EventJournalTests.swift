import Foundation
import Testing

@testable import socktainer

@Suite("EventBroadcaster — persisted history")
struct EventJournalTests {
    private func temporaryFile() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent(EventBroadcaster.persistenceFileName))
    }

    @Test("events broadcast before a restart are replayed by the next broadcaster")
    func survivesRestart() async throws {
        let (directory, file) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = EventBroadcaster(historyLimit: 10, persistenceURL: file)
        await before.broadcast(DockerEvent.simpleEvent(id: "c1", type: "container", status: "create"))
        var network = DockerEvent.make(type: "network", action: "connect", actorID: "n1", attributes: ["container": "c1"])
        network.libpodAttributes = ["name": "web"]
        await before.broadcast(network)

        let after = EventBroadcaster(historyLimit: 10, persistenceURL: file)
        let replayed = await after.recentEvents()
        #expect(replayed.map(\.Action) == ["create", "connect"])
        #expect(replayed.first?.timeNano != 0)
        #expect(replayed.last?.libpodAttributes == ["name": "web"])

        await after.broadcast(DockerEvent.simpleEvent(id: "c1", type: "container", status: "start"))
        let again = EventBroadcaster(historyLimit: 10, persistenceURL: file)
        #expect(await again.recentEvents().map(\.Action) == ["create", "connect", "start"])
    }

    @Test("the file is compacted to the history limit and only the last events are loaded")
    func boundedFile() async throws {
        let (directory, file) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broadcaster = EventBroadcaster(historyLimit: 3, persistenceURL: file)
        for index in 0..<20 {
            await broadcaster.broadcast(DockerEvent.simpleEvent(id: "c\(index)", type: "container", status: "start"))
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count <= 6)

        let reloaded = EventBroadcaster(historyLimit: 3, persistenceURL: file)
        #expect(await reloaded.recentEvents().map(\.id) == ["c17", "c18", "c19"])
    }

    @Test("a torn last line from a crash is skipped")
    func tornLine() async throws {
        let (directory, file) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let broadcaster = EventBroadcaster(historyLimit: 5, persistenceURL: file)
        await broadcaster.broadcast(DockerEvent.simpleEvent(id: "c1", type: "container", status: "die"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"event":{"stat"#.utf8))
        try handle.close()

        let restarted = EventBroadcaster(historyLimit: 5, persistenceURL: file)
        #expect(await restarted.recentEvents().map(\.id) == ["c1"])
        await restarted.broadcast(DockerEvent.simpleEvent(id: "c2", type: "container", status: "start"))
        #expect(await EventBroadcaster(historyLimit: 5, persistenceURL: file).recentEvents().map(\.id) == ["c1", "c2"])
    }

    @Test("a history limit of 0 neither reads nor writes the file")
    func disabled() async throws {
        let (directory, file) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = EventBroadcaster(historyLimit: 5, persistenceURL: file)
        await writer.broadcast(DockerEvent.simpleEvent(id: "c1", type: "container", status: "die"))
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int

        let disabled = EventBroadcaster(historyLimit: 0, persistenceURL: file)
        #expect(await disabled.recentEvents().isEmpty)
        await disabled.broadcast(DockerEvent.simpleEvent(id: "c2", type: "container", status: "die"))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == size)
    }
}
