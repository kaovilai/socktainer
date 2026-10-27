import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("CommitRoute")
struct CommitRouteTests {

    @Test("commits the exported rootfs with the composed config and answers 201 with the image id")
    func commitsContainer() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"],"ExposedPorts":{"80/tcp":{}}}}"#)
        let archive = CommitArchiveClient()
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)

        try await withCommitApp(snapshot: snapshot, archive: archive, images: images) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web&repo=io-committed&tag=v1&comment=hello&author=me&changes=ENV%20A%3D1&changes=LABEL%20k%3Dv"
            ) { res async throws in
                #expect(res.status == .created)
                let body = try JSONDecoder().decode(RESTCommitResponse.self, from: Data(buffer: res.body))
                #expect(body.Id == "sha256:committed")
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.repo == "io-committed")
        #expect(call.tag == "v1")
        #expect(call.comment == "hello")
        #expect(call.author == "me")
        #expect(call.tarContents == "rootfs-of-web")
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["/bin/sh"])
        #expect(config["Env"] as? [String] == ["A=1"])
        #expect(config["Labels"] as? [String: String] == ["k": "v"])
        #expect((config["ExposedPorts"] as? [String: Any])?.keys.sorted() == ["80/tcp"])
        #expect(await archive.exportedIds() == ["web"])
    }

    @Test("a body config overrides the container's command")
    func bodyConfigOverrides() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"]}}"#)
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images) { app in
            try await app.testing().test(
                .POST, "/v1.51/commit?container=web",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: #"{"Cmd":["cat","/data"]}"#)
                }
            ) { res async in
                #expect(res.status == .created)
            }
        }

        let call = try #require(await images.lastCall())
        #expect(call.repo == nil)
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["cat", "/data"])
    }

    @Test("an unknown container is a 404 and nothing is committed")
    func unknownContainer() async throws {
        let images = RecordingCommitClient(baseConfig: "{}")
        try await withCommitApp(snapshot: nil, archive: CommitArchiveClient(), images: images) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=ghost") { res async in
                #expect(res.status == .notFound)
            }
        }
        #expect(await images.lastCall() == nil)
    }

    @Test("a missing container parameter is a 400")
    func missingContainer() async throws {
        try await withCommitApp(snapshot: nil, archive: CommitArchiveClient(), images: RecordingCommitClient(baseConfig: "{}")) { app in
            try await app.testing().test(.POST, "/v1.51/commit") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an invalid change is a 400")
    func invalidChange() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])
        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: RecordingCommitClient(baseConfig: "{}")) { app in
            try await app.testing().test(.POST, "/v1.51/commit?container=web&changes=FROM%20alpine") { res async in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("libpod commit answers podman's stream protocol with the bare hex id")
    func libpodStreamsId() async throws {
        let images = RecordingCommitClient(baseConfig: #"{"config":{"Cmd":["/bin/sh"]}}"#, digest: "sha256:" + String(repeating: "ab", count: 32))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images, libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/commit?container=web&repo=io-img&tag=latest&stream=true&changes=CMD%3D/bin/true") { res async throws in
                #expect(res.status == .ok)
                let line = try JSONDecoder().decode([String: String].self, from: Data(res.body.string.split(separator: "\n")[0].utf8))
                #expect(line["stream"] == String(repeating: "ab", count: 32) + "\n")
            }
        }
        let call = try #require(await images.lastCall())
        let config = try #require(try JSONSerialization.jsonObject(with: call.configJSON) as? [String: Any])
        #expect(config["Cmd"] as? [String] == ["/bin/sh", "-c", "/bin/true"])
    }

    @Test("libpod commit without stream answers an IDResponse")
    func libpodPlainId() async throws {
        let images = RecordingCommitClient(baseConfig: "{}", digest: "sha256:" + String(repeating: "cd", count: 32))
        let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.65.2", network: "bridge", labels: [:])

        try await withCommitApp(snapshot: snapshot, archive: CommitArchiveClient(), images: images, libpod: true) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/commit?container=web") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTCommitResponse.self, from: Data(buffer: res.body))
                #expect(body.Id == String(repeating: "cd", count: 32))
            }
        }
    }
}

// MARK: - Helpers

private func withCommitApp(
    snapshot: ContainerSnapshot?,
    archive: CommitArchiveClient,
    images: RecordingCommitClient,
    libpod: Bool = false,
    test: @escaping (Application) async throws -> Void
) async throws {
    let client: ClientContainerProtocol = snapshot.map { StaticSnapshotClientMock(snapshot: $0) } ?? NoContainerClient()
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.storage[AppleContainerAppSupportUrlKey.self] = FileManager.default.temporaryDirectory
        if libpod {
            try app.register(collection: LibpodCommitRoute(containerClient: client, archiveClient: archive, imageClient: images))
        } else {
            try app.register(collection: CommitRoute(containerClient: client, archiveClient: archive, imageClient: images))
        }
        try await test(app)
    }
}

private actor RecordingCommitClient: ClientImageCommitProtocol {
    struct Call: Sendable {
        let repo: String?
        let tag: String?
        let comment: String?
        let author: String?
        let configJSON: Data
        let tarContents: String
    }

    private let baseConfig: Data
    private let digest: String
    private var calls: [Call] = []

    init(baseConfig: String, digest: String = "sha256:committed") {
        self.baseConfig = Data(baseConfig.utf8)
        self.digest = digest
    }

    func lastCall() -> Call? { calls.last }

    func commitImage(
        tarPath: URL, repo: String?, tag: String?, comment: String?, author: String?, configJSON: Data, platform: Platform,
        appleContainerAppSupportUrl: URL, logger: Logger
    ) async throws -> (reference: String?, digest: String) {
        let contents = try String(contentsOf: tarPath, encoding: .utf8)
        calls.append(Call(repo: repo, tag: tag, comment: comment, author: author, configJSON: configJSON, tarContents: contents))
        return (repo, digest)
    }

    func rawImageConfig(reference: String, platform: Platform, appleContainerAppSupportUrl: URL) async throws -> Data {
        baseConfig
    }
}

private actor CommitArchiveClient: ClientArchiveProtocol {
    private var exported: [String] = []

    func exportedIds() -> [String] { exported }

    nonisolated func getRootfsPath(containerId: String) -> URL {
        URL(fileURLWithPath: "/nonexistent/rootfs.ext4")
    }

    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func statPath(container: ContainerSnapshot, path: String) async throws -> PathStat {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        throw ClientArchiveError.operationFailed(message: "not under test")
    }

    func exportRootfs(container: ContainerSnapshot) async throws -> URL {
        exported.append(container.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-test-\(UUID().uuidString).tar")
        try Data("rootfs-of-\(container.id)".utf8).write(to: url)
        return url
    }
}

private struct NoContainerClient: ClientContainerProtocol {
    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { nil }
    func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) { ([], 0) }
}
