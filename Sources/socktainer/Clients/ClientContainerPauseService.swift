import ContainerAPIClient
import ContainerResource
import Foundation
import Synchronization
import Vapor

/// Which running containers socktainer has paused, keyed by native ID. Each entry remembers the
/// start of the run it paused, so a container that stopped and started again since no longer
/// reads as paused without anything having to clear the entry.
///
/// The set is persisted next to socktainer's other per-container records: the processes stay
/// SIGSTOPped across a daemon restart, so forgetting them would report a frozen container as
/// running and refuse to unpause it.
final class ContainerPauseState: Sendable {
    static let shared = ContainerPauseState()
    static let fileName = "socktainer-paused.json"

    private struct State {
        var paused: [String: Date?] = [:]
        var fileURL: URL?
    }

    private let state = Mutex<State>(State())
    private let log = Logger(label: "socktainer.pause")

    init(fileURL: URL? = nil) {
        guard let fileURL else { return }
        let loaded = Self.load(from: fileURL, log: log)
        state.withLock {
            $0.fileURL = fileURL
            $0.paused = loaded
        }
    }

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent(Self.fileName)
        let loaded = Self.load(from: url, log: log)
        state.withLock {
            $0.fileURL = url
            $0.paused = loaded
        }
    }

    func markPaused(_ container: ContainerSnapshot) {
        update { $0[container.id] = .some(container.startedDate) }
    }

    func markUnpaused(id: String) {
        update { _ = $0.removeValue(forKey: id) }
    }

    func isPaused(_ container: ContainerSnapshot) -> Bool {
        guard container.status == .running else { return false }
        return state.withLock { state in
            guard let startedDate = state.paused[container.id] else { return false }
            return Self.sameStart(startedDate, container.startedDate)
        }
    }

    /// IDs of the containers recorded as paused, whether or not they still are.
    var recordedIDs: Set<String> {
        state.withLock { Set($0.paused.keys) }
    }

    /// Drops every entry whose container is gone, stopped, or started again since it was paused,
    /// given the containers that exist now. Run once at startup, after a restart of socktainer.
    func reconcile(with containers: [ContainerSnapshot]) {
        let current = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        update { paused in
            paused = paused.filter { id, startedDate in
                guard let container = current[id], container.status == .running else { return false }
                return Self.sameStart(startedDate, container.startedDate)
            }
        }
    }

    /// Start dates read back from JSON may differ from the live ones in the last bits of the
    /// floating-point value, so they compare within a millisecond.
    private static func sameStart(_ recorded: Date?, _ current: Date?) -> Bool {
        switch (recorded, current) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return abs(lhs.timeIntervalSince(rhs)) < 0.001
        default: return false
        }
    }

    private func update(_ body: (inout [String: Date?]) -> Void) {
        state.withLock { state in
            let before = state.paused
            body(&state.paused)
            guard state.paused != before, let fileURL = state.fileURL else { return }
            do {
                try JSONEncoder().encode(state.paused.mapValues { $0?.timeIntervalSince1970 }).write(to: fileURL, options: .atomic)
            } catch {
                log.error("could not save paused containers to \(fileURL.path): \(error)")
            }
        }
    }

    private static func load(from url: URL, log: Logger) -> [String: Date?] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let stored = try JSONDecoder().decode([String: TimeInterval?].self, from: Data(contentsOf: url))
            return stored.mapValues { $0.map { Date(timeIntervalSince1970: $0) } }
        } catch {
            log.error("could not load paused containers from \(url.path) — containers paused by an earlier run read as running: \(error)")
            return [:]
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
