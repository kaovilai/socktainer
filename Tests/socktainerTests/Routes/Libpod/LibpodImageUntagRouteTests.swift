import ContainerAPIClient
import ContainerPersistence
import Foundation
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// An in-memory image store: reference -> digest.
private final class FakeUntagStore: ImageUntagStore, Sendable {
    private let refs: Mutex<[String: String]>

    init(_ refs: [String: String]) { self.refs = Mutex(refs) }

    var references: [String: String] { refs.withLock { $0 } }

    func digest(of name: String, config: ContainerSystemConfig) async throws -> String {
        let normalized = try ClientImage.normalizeReference(name, containerSystemConfig: config)
        guard let digest = refs.withLock({ $0[normalized] }) else { throw ClientImageError.notFound(id: name) }
        return digest
    }

    func references(to digest: String) async throws -> [String] {
        refs.withLock { $0.filter { $0.value == digest }.map(\.key).sorted() }
    }

    func tag(existing: String, new: String, config: ContainerSystemConfig) async throws {
        refs.withLock { $0[new] = $0[existing] }
    }

    func delete(reference: String) async throws {
        refs.withLock { _ = $0.removeValue(forKey: reference) }
    }
}

private let mt1 = "docker.io/e2e/mt:1"
private let mt2 = "docker.io/e2e/mt:2"

private func withUntagApp(_ store: FakeUntagStore, _ body: (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: LibpodImageUntagRoute(systemConfig: ContainerSystemConfig(), store: store))
        try await body(app)
    }
}

@Suite("LibpodImageUntagRoute")
struct LibpodImageUntagRouteTests {
    @Test("untag with repo and tag removes only that name")
    func untagOneName() async throws {
        let store = FakeUntagStore([mt1: "sha256:a", mt2: "sha256:a"])
        try await withUntagApp(store) { app in
            try await app.testing().test(.POST, "/v6.1.4/libpod/images/e2e/mt:2/untag?repo=e2e/mt&tag=2") { res async in
                #expect(res.status == .created)
            }
        }
        #expect(store.references == [mt1: "sha256:a"])
    }

    @Test("untag without repo removes every name and keeps the image as dangling")
    func untagAllKeepsDangling() async throws {
        let store = FakeUntagStore([mt1: "sha256:a", mt2: "sha256:a", "docker.io/other:1": "sha256:b"])
        try await withUntagApp(store) { app in
            try await app.testing().test(.POST, "/v6.1.4/libpod/images/e2e/mt:1/untag") { res async in
                #expect(res.status == .created)
            }
        }
        #expect(store.references == ["untagged@sha256:a": "sha256:a", "docker.io/other:1": "sha256:b"])
    }

    @Test("untagging the image's last name keeps it as dangling instead of removing it")
    func untagLastName() async throws {
        let store = FakeUntagStore([mt1: "sha256:a"])
        try await withUntagApp(store) { app in
            try await app.testing().test(.POST, "/v6.1.4/libpod/images/e2e/mt:1/untag?repo=e2e/mt&tag=1") { res async in
                #expect(res.status == .created)
            }
        }
        #expect(store.references == ["untagged@sha256:a": "sha256:a"])
    }

    @Test("a name the image does not carry, or an unknown image, is a 404")
    func unknownNames() async throws {
        let store = FakeUntagStore([mt1: "sha256:a", "docker.io/other:1": "sha256:b"])
        try await withUntagApp(store) { app in
            try await app.testing().test(.POST, "/v6.1.4/libpod/images/e2e/mt:1/untag?repo=other&tag=1") { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.POST, "/v6.1.4/libpod/images/nosuch:1/untag") { res async in
                #expect(res.status == .notFound)
            }
        }
        #expect(store.references.count == 2)
    }
}
