import Foundation
import Testing

@testable import socktainer

@Suite("Pod store")
struct PodStoreTests {
    private func makeRecord(_ id: String, _ name: String) -> PodRecord {
        PodRecord(id: id, name: name, created: Date(), labels: [:], hostname: "", network: nil, ownsNetwork: false, sharedNamespaces: [])
    }

    @Test("a pod resolves by name, full ID and unambiguous ID prefix")
    func resolve() async throws {
        let store = PodStore()
        let pod = try await store.create(name: "web") { id, name in makeRecord(id, name) }
        #expect(pod.id.count == 64)
        #expect(await store.resolve("web") == pod)
        #expect(await store.resolve(pod.id) == pod)
        #expect(await store.resolve(String(pod.id.prefix(12))) == pod)
        #expect(await store.resolve("nope") == nil)
        #expect(await store.resolve("") == nil)
    }

    @Test("a second pod with the same name is refused, and a bad name is rejected")
    func nameRules() async throws {
        let store = PodStore()
        _ = try await store.create(name: "dup") { id, name in makeRecord(id, name) }
        await #expect(throws: PodStoreError.self) {
            _ = try await store.create(name: "dup") { id, name in makeRecord(id, name) }
        }
        await #expect(throws: PodStoreError.self) {
            _ = try await store.create(name: "-bad name") { id, name in makeRecord(id, name) }
        }
        #expect(await store.all().count == 1)
    }

    @Test("a pod created without a name is named after its short ID")
    func generatedName() async throws {
        let store = PodStore()
        let pod = try await store.create(name: "") { id, name in makeRecord(id, name) }
        #expect(pod.name == String(pod.id.prefix(12)))
    }

    @Test("pods survive a daemon restart, and removed pods stay removed")
    func persistence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pods-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PodStore(fileURL: url)
        let kept = try await store.create(name: "kept") { id, name in makeRecord(id, name) }
        let gone = try await store.create(name: "gone") { id, name in makeRecord(id, name) }
        try await store.remove(id: gone.id)

        let reloaded = PodStore(fileURL: url)
        #expect(await reloaded.all().map(\.name) == ["kept"])
        #expect(await reloaded.resolve("kept")?.id == kept.id)
    }
}
