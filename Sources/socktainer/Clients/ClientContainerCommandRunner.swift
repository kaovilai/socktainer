import ContainerAPIClient
import ContainerResource
import Foundation

/// What a command run inside a container produced.
struct ContainerCommandOutput: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ContainerCommandError: Error, CustomStringConvertible {
    /// The process could not be created or started, most often because the image lacks the executable.
    case startFailed(executable: String, underlying: String)

    var description: String {
        switch self {
        case .startFailed(let executable, let underlying):
            return "failed to run \(executable) in the container: \(underlying)"
        }
    }
}

/// Runs a short-lived command inside a running container and collects its output, for routes
/// that answer from what the container reports about itself (`top`, a healthcheck run on demand).
/// A protocol so route tests can answer with canned output instead of a real exec.
protocol ClientContainerCommandRunner: Sendable {
    /// Runs `command` (executable first) in `container`. With `asRoot`, the command runs as uid 0
    /// rather than the container's configured user.
    func run(container: ContainerSnapshot, command: [String], asRoot: Bool) async throws -> ContainerCommandOutput
}

struct ClientContainerCommandRunnerService: ClientContainerCommandRunner {
    func run(container: ContainerSnapshot, command: [String], asRoot: Bool) async throws -> ContainerCommandOutput {
        guard let executable = command.first else {
            throw ContainerCommandError.startFailed(executable: "", underlying: "empty command")
        }
        let processConfig = Self.processConfiguration(base: container.configuration.initProcess, command: command, asRoot: asRoot)

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw ContainerCommandError.startFailed(executable: executable, underlying: "failed to create I/O pipes")
        }
        let client = ContainerClient()
        let process: ClientProcess
        do {
            process = try await client.createProcess(
                containerId: container.id,
                processId: "cmd-\(UUID().uuidString.lowercased())",
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw ContainerCommandError.startFailed(executable: executable, underlying: String(describing: error))
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw ContainerCommandError.startFailed(executable: executable, underlying: String(describing: error))
        }
        let (exitCode, stdout, stderr) = try await pipes.collectOutput { try await process.wait() }
        return ContainerCommandOutput(
            exitCode: exitCode,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    /// The container's init process with `command` swapped in, like `docker exec` without `-u`
    /// (or with `-u 0` when `asRoot`).
    static func processConfiguration(base: ProcessConfiguration, command: [String], asRoot: Bool) -> ProcessConfiguration {
        var processConfig = base
        processConfig.executable = command[0]
        processConfig.arguments = Array(command.dropFirst())
        processConfig.terminal = false
        if asRoot {
            processConfig.user = .id(uid: 0, gid: 0)
            processConfig.supplementalGroups = []
        }
        return processConfig
    }
}
