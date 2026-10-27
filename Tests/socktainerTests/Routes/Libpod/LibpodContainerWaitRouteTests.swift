import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Real podman's libpod `wait` endpoint (`condition=`, repeatable) uses the container's own
/// lowercase status names ("stopped", "exited", "running", "paused", "created", "configured"),
/// not Docker compat's `wait`-specific vocabulary (`ContainerWaitCondition`: "not-running",
/// "next-exit", "removed", "healthy") — passing a real podman condition straight to
/// `ContainerWaitCondition(rawValue:)` rejected every explicit condition a real `podman wait`
/// call would send.
@Suite("LibpodContainerWaitRoute — condition mapping")
struct LibpodContainerWaitRouteTests {
    @Test("condition=stopped (real podman's own vocabulary) maps to notRunning, not a 400")
    func stoppedConditionMapsToNotRunning() async throws {
        let client = RecordingWaitClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=stopped") { res async throws in
                #expect(res.status == .ok)
                // Podman's binding decodes the exit code as a bare JSON integer, not Docker's
                // `{"StatusCode": N}` object.
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            }
        }
        #expect(await client.receivedCondition == .notRunning)
    }

    @Test("condition=removing (real podman's in-progress-removal status) maps to removed, not a 400")
    func removingConditionMapsToRemoved() async throws {
        let client = RecordingWaitClient()

        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))

            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=removing") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await client.receivedCondition == .removed)
    }

    @Test("condition=paused answers -1 once the container is paused")
    func pausedConditionAnswersMinusOne() async throws {
        // Pause state is process-wide: a distinct ID keeps parallel tests from clearing this entry.
        let snapshot = makeSnapshot(status: .running, id: "wait-paused-condition")
        ContainerPauseState.shared.markPaused(snapshot)
        defer { ContainerPauseState.shared.markUnpaused(id: snapshot.id) }
        let client = RecordingWaitClient(snapshot: snapshot)
        try await withWaitRoute(client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=paused") { res async throws in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "-1")
            }
        }
        #expect(await client.receivedCondition == nil)
    }

    @Test("condition=running does not hold for a paused container: podman reports it as paused")
    func runningConditionIgnoresPausedContainer() async throws {
        let snapshot = makeSnapshot(status: .running, id: "wait-running-while-paused")
        ContainerPauseState.shared.markPaused(snapshot)
        defer { ContainerPauseState.shared.markUnpaused(id: snapshot.id) }
        let client = RecordingWaitClient(snapshot: snapshot)
        try await withApp(configure: { _ in }) { app in
            let probe = Task { await LibpodContainerWaitRoute.stateReached([.running], nativeId: snapshot.id, client: client, app: app) }
            try await Task.sleep(nanoseconds: 2 * LibpodContainerWaitRoute.statePollIntervalNs)
            probe.cancel()
            #expect(await probe.value == nil)
        }
    }

    @Test("condition=stopping is still 501, not a misleading 400 'invalid condition'")
    func stoppingConditionIsNotImplemented() async throws {
        let client = RecordingWaitClient()
        try await withWaitRoute(client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=stopping") { res async throws in
                #expect(res.status == .notImplemented)
            }
        }
        #expect(await client.receivedCondition == nil)
    }

    @Test("condition=created answers -1 at once for a container that never started, as podman does for a state")
    func createdConditionAnswersMinusOne() async throws {
        let client = RecordingWaitClient()
        try await withWaitRoute(client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=created") { res async throws in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "-1")
            }
        }
        #expect(await client.receivedCondition == nil)
    }

    @Test("condition=running answers -1 once the container runs")
    func runningConditionAnswersMinusOne() async throws {
        let client = RecordingWaitClient(snapshot: makeSnapshot(status: .running))
        try await withWaitRoute(client) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=running") { res async throws in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "-1")
            }
        }
    }

    @Test("several conditions are ORed: the first one met answers, not just the first one given")
    func multipleConditionsAreOred() async throws {
        let client = RecordingWaitClient(exitCode: 4)
        try await withWaitRoute(client) { app in
            // Never started: `running` never holds, so only `stopped` can answer.
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=running&condition=stopped") { res async throws in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).trimmingCharacters(in: .whitespacesAndNewlines) == "4")
            }
        }
        #expect(await client.receivedCondition == .notRunning)
    }

    @Test("an unknown condition is a 400")
    func unknownConditionIsBadRequest() async throws {
        try await withWaitRoute(RecordingWaitClient()) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=bogus") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a health condition on a container without a healthcheck fails instead of waiting forever")
    func healthConditionWithoutHealthcheckFails() async throws {
        try await withWaitRoute(RecordingWaitClient(snapshot: makeSnapshot(status: .running))) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/ctr/wait?condition=healthy") { res async throws in
                #expect(res.status == .internalServerError)
            }
        }
    }

    private func withWaitRoute(_ client: RecordingWaitClient, _ test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodContainerWaitRoute(client: client))
            try await test(app)
        }
    }
}

private actor RecordingWaitClient: ClientContainerProtocol {
    private(set) var receivedCondition: ContainerWaitCondition?
    private let snapshot: ContainerSnapshot
    private let exitCode: Int64

    init(snapshot: ContainerSnapshot = makeSnapshot(status: .stopped), exitCode: Int64 = 0) {
        self.snapshot = snapshot
        self.exitCode = exitCode
    }

    func list(showAll: Bool, filters: [String: [String]]) async throws -> [ContainerSnapshot] { [] }
    func getContainer(id: String) async throws -> ContainerSnapshot? { snapshot }
    nonisolated func enforceContainerRunning(container: ContainerSnapshot) throws {}
    func start(id: String, detachKeys: String?) async throws {}
    func stop(id: String, signal: String?, timeout: Int?) async throws {}
    func restart(id: String, signal: String?, timeout: Int?) async throws {}
    func kill(id: String, signal: String?) async throws {}
    func delete(id: String) async throws {}
    func wait(id: String, condition: ContainerWaitCondition) async throws -> RESTContainerWait {
        receivedCondition = condition
        return RESTContainerWait(statusCode: exitCode)
    }
    func prune(filters: [String: [String]]) async throws -> (deletedContainers: [String], spaceReclaimed: Int64) {
        ([], 0)
    }
}

/// The Docker-compat wait handler (which this route delegates to) 404s on a container that doesn't exist.
/// A stopped snapshot has no start date, so it is a container that never started.
private func makeSnapshot(status: RuntimeStatus, id: String = "ctr") -> ContainerSnapshot {
    let process = ProcessConfiguration(
        executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
    let image = ImageDescription(
        reference: "alpine:latest",
        descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
    let config = ContainerConfiguration(id: id, image: image, process: process)
    return ContainerSnapshot(
        configuration: config, status: status, networks: [], startedDate: status == .running ? Date(timeIntervalSinceNow: -5) : nil)
}
