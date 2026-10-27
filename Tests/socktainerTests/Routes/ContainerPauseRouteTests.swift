import ContainerAPIClient
import ContainerResource
import Foundation
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Records the signals sent to each container's PID 1.
private final class InitSignals: Sendable {
    private let sent = Mutex<[String]>([])
    var signals: [String] { sent.withLock { $0 } }
    func record(_ signal: String) { sent.withLock { $0.append(signal) } }
}

private func runningSnapshot(_ id: String, startedAt: Date = Date(timeIntervalSince1970: 1_000)) throws -> ContainerSnapshot {
    var snapshot = try makeContainerSnapshot(nativeId: id, ip: "192.168.64.2", network: "default", labels: [:], status: .running)
    snapshot.startedDate = startedAt
    return snapshot
}

private func makePauser(_ signals: InitSignals, runner: CannedCommandRunner, state: ContainerPauseState) -> ContainerPauseService {
    ContainerPauseService(runner: runner, signalInit: { _, signal in signals.record(signal) }, state: state)
}

@Suite("ContainerPauseService")
struct ContainerPauseServiceTests {
    @Test("Pause stops every other process from inside, then PID 1; unpause resumes PID 1 first")
    func pauseThenUnpause() async throws {
        let signals = InitSignals()
        let runner = CannedCommandRunner(stdout: "")
        let state = ContainerPauseState()
        let pauser = makePauser(signals, runner: runner, state: state)
        let container = try runningSnapshot("web")

        try await pauser.pause(container, logger: Logger(label: "test"))
        #expect(state.isPaused(container))
        #expect(signals.signals == ["SIGSTOP"])
        #expect(runner.commands == [["/bin/sh", "-c", "kill -STOP -1"]])

        try await pauser.unpause(container, logger: Logger(label: "test"))
        #expect(!state.isPaused(container))
        #expect(signals.signals == ["SIGSTOP", "SIGCONT"])
        #expect(runner.commands.last == ["/bin/sh", "-c", "kill -CONT -1"])
    }

    @Test("An image without a shell still gets PID 1 stopped")
    func noShell() async throws {
        let signals = InitSignals()
        let runner = CannedCommandRunner { _ in throw ContainerCommandError.startFailed(executable: "/bin/sh", underlying: "not found") }
        let state = ContainerPauseState()
        let container = try runningSnapshot("web")
        try await makePauser(signals, runner: runner, state: state).pause(container, logger: Logger(label: "test"))
        #expect(state.isPaused(container))
        #expect(signals.signals == ["SIGSTOP"])
    }

    @Test("Pausing twice, unpausing a running container, and pausing a stopped one are refused")
    func refusals() async throws {
        let signals = InitSignals()
        let state = ContainerPauseState()
        let pauser = makePauser(signals, runner: CannedCommandRunner(stdout: ""), state: state)
        let container = try runningSnapshot("web")
        let logger = Logger(label: "test")

        await #expect(throws: ContainerPauseError.notPaused("web")) { try await pauser.unpause(container, logger: logger) }
        try await pauser.pause(container, logger: logger)
        await #expect(throws: ContainerPauseError.alreadyPaused("web")) { try await pauser.pause(container, logger: logger) }

        let stopped = try makeContainerSnapshot(nativeId: "db", ip: "192.168.64.3", network: "default", labels: [:], status: .stopped)
        await #expect(throws: ContainerPauseError.notRunning("db")) { try await pauser.pause(stopped, logger: logger) }
        #expect(signals.signals == ["SIGSTOP"])
    }

    @Test("A container that stopped or restarted since it was paused no longer reads as paused")
    func staleAfterRestart() throws {
        let state = ContainerPauseState()
        let container = try runningSnapshot("web")
        state.markPaused(container)
        #expect(state.isPaused(container))
        #expect(container.mobyState == "running")  // the shared state is not this one

        var stopped = container
        stopped.status = .stopped
        #expect(!state.isPaused(stopped))
        #expect(!state.isPaused(try runningSnapshot("web", startedAt: Date(timeIntervalSince1970: 2_000))))
    }

    @Test("Paused containers survive a daemon restart through the state file")
    func persistedAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ContainerPauseState.fileName)

        let web = try runningSnapshot("web", startedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))
        let db = try runningSnapshot("db")
        let before = ContainerPauseState(fileURL: url)
        before.markPaused(web)
        before.markPaused(db)
        before.markUnpaused(id: "db")

        let after = ContainerPauseState()
        after.configure(storageDirectory: directory)
        #expect(after.isPaused(web))
        #expect(!after.isPaused(db))
        #expect(after.recordedIDs == ["web"])
    }

    @Test("Reconciling after a restart drops containers that are gone, stopped or restarted")
    func reconcile() throws {
        let state = ContainerPauseState()
        let kept = try runningSnapshot("kept")
        let restarted = try runningSnapshot("restarted")
        var stopped = try runningSnapshot("stopped")
        for container in [kept, restarted, stopped, try runningSnapshot("gone")] {
            state.markPaused(container)
        }
        stopped.status = .stopped
        state.reconcile(with: [kept, stopped, try runningSnapshot("restarted", startedAt: Date(timeIntervalSince1970: 5_000))])
        #expect(state.recordedIDs == ["kept"])
        #expect(state.isPaused(kept))
        #expect(!state.isPaused(restarted))
    }

    @Test("A paused container's Docker state is paused")
    func mobyState() throws {
        let container = try runningSnapshot("pause-moby-state-test")
        ContainerPauseState.shared.markPaused(container)
        defer { ContainerPauseState.shared.markUnpaused(id: container.id) }
        #expect(container.mobyState == "paused")
    }
}

@Suite("ContainerPauseRoute")
struct ContainerPauseRouteTests {
    private func withPauseApp(
        _ snapshot: ContainerSnapshot, _ pauser: ContainerPauseService, _ body: (Application) async throws -> Void
    ) async throws {
        let client = StaticSnapshotClientMock(snapshot: snapshot)
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.middleware.use(ErrorMiddleware.default(environment: app.environment))
            try app.register(collection: ContainerPauseRoute(client: client, pauser: pauser))
            try app.register(collection: ContainerUnpauseRoute(client: client, pauser: pauser))
            try app.register(collection: LibpodContainerPauseRoute(client: client, pauser: pauser))
            try app.register(collection: LibpodContainerUnpauseRoute(client: client, pauser: pauser))
            try await body(app)
        }
    }

    @Test("docker pause/unpause answer 204, and a repeat is a conflict")
    func docker() async throws {
        let signals = InitSignals()
        let pauser = makePauser(signals, runner: CannedCommandRunner(stdout: ""), state: ContainerPauseState())
        try await withPauseApp(try runningSnapshot("web"), pauser) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/pause") { res async in #expect(res.status == .noContent) }
            try await app.testing().test(.POST, "/v1.51/containers/web/pause") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already paused"))
            }
            try await app.testing().test(.POST, "/v1.51/containers/web/unpause") { res async in #expect(res.status == .noContent) }
            try await app.testing().test(.POST, "/v1.51/containers/web/unpause") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("is not paused"))
            }
        }
        #expect(signals.signals == ["SIGSTOP", "SIGCONT"])
    }

    @Test("podman pause/unpause answer 204")
    func libpod() async throws {
        let signals = InitSignals()
        let pauser = makePauser(signals, runner: CannedCommandRunner(stdout: ""), state: ContainerPauseState())
        try await withPauseApp(try runningSnapshot("web"), pauser) { app in
            try await app.testing().test(.POST, "/v5.0.0/libpod/containers/web/pause") { res async in #expect(res.status == .noContent) }
            try await app.testing().test(.POST, "/v5.0.0/libpod/containers/web/unpause") { res async in #expect(res.status == .noContent) }
        }
        #expect(signals.signals == ["SIGSTOP", "SIGCONT"])
    }

    @Test("Pausing a stopped container is a conflict")
    func stopped() async throws {
        let signals = InitSignals()
        let pauser = makePauser(signals, runner: CannedCommandRunner(stdout: ""), state: ContainerPauseState())
        let stopped = try makeContainerSnapshot(nativeId: "web", ip: "192.168.64.2", network: "default", labels: [:], status: .stopped)
        try await withPauseApp(stopped, pauser) { app in
            try await app.testing().test(.POST, "/v1.51/containers/web/pause") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("is not running"))
            }
        }
        #expect(signals.signals.isEmpty)
    }
}
