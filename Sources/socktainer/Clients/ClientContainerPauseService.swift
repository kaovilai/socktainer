import ContainerAPIClient
import ContainerResource
import Foundation
import Synchronization
import Vapor

/// Which running containers socktainer has paused, keyed by native ID. Each entry remembers the
/// start of the run it paused, so a container that stopped and started again since no longer
/// reads as paused without anything having to clear the entry.
final class ContainerPauseState: Sendable {
    static let shared = ContainerPauseState()

    private let paused = Mutex<[String: Date?]>([:])

    func markPaused(_ container: ContainerSnapshot) {
        paused.withLock { $0[container.id] = .some(container.startedDate) }
    }

    func markUnpaused(id: String) {
        paused.withLock { _ = $0.removeValue(forKey: id) }
    }

    func isPaused(_ container: ContainerSnapshot) -> Bool {
        guard container.status == .running else { return false }
        return paused.withLock { state in
            guard let startedDate = state[container.id] else { return false }
            return startedDate == container.startedDate
        }
    }
}

enum ContainerPauseError: Error, Equatable {
    case notRunning(String)
    case alreadyPaused(String)
    case notPaused(String)
}

/// Pauses a container by stopping every process in it with SIGSTOP, and unpauses it with SIGCONT.
///
/// Apple Container 1.6.0 offers no pause primitive: `ContainerClient` has no pause/resume call,
/// and the VM-level `pause()` in Containerization is not reachable through the container API
/// service. Docker's cgroup freezer is out of reach too, because a process exec'd to thaw the
/// cgroup would start frozen. Signals reach every process instead: SIGSTOP cannot be caught or
/// ignored, a stopped process gets no CPU, and SIGCONT resumes it where it was.
///
/// `kill -STOP -1` run inside the container reaches all its processes except the caller and PID 1;
/// PID 1 is signalled through `ContainerClient.kill`, from outside its PID namespace, where the
/// kernel delivers SIGSTOP to a namespace's init. An image without a shell gets only PID 1
/// stopped, which covers the usual single-process image.
struct ContainerPauseService: Sendable {
    typealias SignalInit = @Sendable (_ containerId: String, _ signal: String) async throws -> Void

    let runner: ClientContainerCommandRunner
    let signalInit: SignalInit
    let state: ContainerPauseState

    init(
        runner: ClientContainerCommandRunner = ClientContainerCommandRunnerService(),
        signalInit: @escaping SignalInit = { id, signal in try await ContainerClient().kill(id: id, signal: signal) },
        state: ContainerPauseState = .shared
    ) {
        self.runner = runner
        self.signalInit = signalInit
        self.state = state
    }

    static func signalOthersCommand(_ signal: String) -> [String] {
        ["/bin/sh", "-c", "kill -\(signal) -1"]
    }

    func pause(_ container: ContainerSnapshot, logger: Logger) async throws {
        guard container.status == .running else { throw ContainerPauseError.notRunning(container.id) }
        guard !state.isPaused(container) else { throw ContainerPauseError.alreadyPaused(container.id) }
        await signalOthers(container, "STOP", logger: logger)
        try await signalInit(container.id, "SIGSTOP")
        state.markPaused(container)
    }

    func unpause(_ container: ContainerSnapshot, logger: Logger) async throws {
        guard state.isPaused(container) else { throw ContainerPauseError.notPaused(container.id) }
        try await signalInit(container.id, "SIGCONT")
        await signalOthers(container, "CONT", logger: logger)
        state.markUnpaused(id: container.id)
    }

    /// Signals every process but PID 1 from inside the container. `kill -1` exits non-zero when
    /// there is no other process to signal, so its exit status is only logged.
    private func signalOthers(_ container: ContainerSnapshot, _ signal: String, logger: Logger) async {
        do {
            let output = try await runner.run(container: container, command: Self.signalOthersCommand(signal), asRoot: true)
            if output.exitCode != 0 {
                logger.debug("pause: kill -\(signal) -1 in \(container.id) exited \(output.exitCode): \(output.stderr)")
            }
        } catch {
            logger.info("pause: could not signal the processes besides PID 1 in \(container.id): \(error)")
        }
    }
}
