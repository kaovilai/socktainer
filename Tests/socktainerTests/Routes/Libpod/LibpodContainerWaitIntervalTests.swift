import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("Go duration parsing")
struct GoDurationTests {
    @Test("parses Go's time.ParseDuration syntax")
    func parses() {
        #expect(GoDuration.seconds("250ms") == 0.25)
        #expect(GoDuration.seconds("1s") == 1)
        #expect(GoDuration.seconds("1.5s") == 1.5)
        #expect(GoDuration.seconds("1h30m") == 5400)
        #expect(GoDuration.seconds("100us") == 0.0001)
        #expect(GoDuration.seconds("100µs") == 0.0001)
        #expect(GoDuration.seconds("500ns") == 5e-7)
        #expect(GoDuration.seconds("0") == 0)
        #expect(GoDuration.seconds("-2s") == -2)
    }

    @Test("rejects what Go rejects")
    func rejects() {
        #expect(GoDuration.seconds("") == nil)
        #expect(GoDuration.seconds("250") == nil)
        #expect(GoDuration.seconds("ms") == nil)
        #expect(GoDuration.seconds("1x") == nil)
        #expect(GoDuration.seconds("1.2.3s") == nil)
        #expect(GoDuration.seconds("abc") == nil)
    }
}

/// podman's libpod wait takes `interval` (a Go duration, default 250ms): how often it checks
/// the condition.
@Suite("LibpodContainerWaitRoute — interval")
struct LibpodContainerWaitIntervalTests {
    @Test("interval sets how often a state condition is checked")
    func intervalIsHonoured() async throws {
        // Running only from the 6th lookup on: at 250ms per check that takes over a second.
        let client = FlippingClient(runningAfterLookups: 6)
        try await withWaitRoute(client) { app in
            let started = Date()
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=running&interval=5ms") { res async throws in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "-1")
            }
            #expect(Date().timeIntervalSince(started) < 0.75)
        }
    }

    @Test("an invalid interval is a 400, as in podman")
    func invalidIntervalIsBadRequest() async throws {
        try await withWaitRoute(FlippingClient(runningAfterLookups: 0)) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=running&interval=soon") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("no interval keeps podman's 250ms default")
    func defaultInterval() async throws {
        try await withApp(configure: { _ in }) { app in
            let req = Request(application: app, method: .POST, url: URI(string: "/libpod/containers/ctr/wait"), on: app.eventLoopGroup.next())
            let fallback = try LibpodContainerWaitRoute.pollInterval(from: req)
            #expect(fallback == 250_000_000)
            let fast = Request(
                application: app, method: .POST, url: URI(string: "/libpod/containers/ctr/wait?interval=1s"), on: app.eventLoopGroup.next())
            let oneSecond = try LibpodContainerWaitRoute.pollInterval(from: fast)
            #expect(oneSecond == 1_000_000_000)
        }
    }

    private func withWaitRoute(_ client: FlippingClient, _ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))
            try await test(app)
        }
    }
}

/// Reports a created container until `runningAfterLookups` lookups have been made, then a running one.
private actor FlippingClient: ClientContainerProtocol {
    private let runningAfterLookups: Int
    private var lookups = 0

    init(runningAfterLookups: Int) {
        self.runningAfterLookups = runningAfterLookups
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? {
        lookups += 1
        let running = lookups > runningAfterLookups
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        let config = ContainerConfiguration(id: "ctr", image: image, process: process)
        return ContainerSnapshot(
            configuration: config, status: running ? .running : .stopped, networks: [],
            startedDate: running ? Date(timeIntervalSinceNow: -1) : nil)
    }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        RESTContainerWait(statusCode: 0)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}
