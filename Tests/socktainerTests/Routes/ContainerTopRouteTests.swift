import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Answers every command with canned output and records the commands it was asked to run.
final class CannedCommandRunner: ClientContainerCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    private let respond: @Sendable ([String]) throws -> ContainerCommandOutput

    init(_ respond: @escaping @Sendable ([String]) throws -> ContainerCommandOutput) {
        self.respond = respond
    }

    convenience init(stdout: String, exitCode: Int32 = 0, stderr: String = "") {
        self.init { _ in ContainerCommandOutput(exitCode: exitCode, stdout: stdout, stderr: stderr) }
    }

    var commands: [[String]] { lock.withLock { _commands } }

    func run(container: ContainerSnapshot, command: [String], asRoot: Bool) async throws -> ContainerCommandOutput {
        lock.withLock { _commands.append(command) }
        return try respond(command)
    }
}

private func withTopApp(
    status: RuntimeStatus = .running, runner: CannedCommandRunner, broadcaster: EventBroadcaster? = nil,
    _ body: (Application) async throws -> Void
) async throws {
    let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.64.2", network: "default", labels: [:], status: status)
    let client = StaticSnapshotClientMock(snapshot: snapshot)
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        if let broadcaster { app.storage[EventBroadcasterKey.self] = broadcaster }
        try app.register(collection: ContainerTopRoute(client: client, runner: runner))
        try app.register(collection: LibpodContainerTopRoute(client: client, runner: runner))
        try await body(app)
    }
}

// busybox `ps -ef` output, including the row of the `ps` that printed it.
private let busyboxPSEF = """
    PID   USER     TIME  COMMAND
        1 root      0:00 sleep 300
        7 root      0:00 /bin/sh -c while true; do sleep 1; done
       12 root      0:00 ps -ef

    """

@Suite("ContainerTop parsing")
struct ContainerTopParsingTests {
    @Test("Docker parse joins the command line back into one column and drops the ps row")
    func dockerParse() throws {
        let top = try ContainerTop.parseDockerOutput(busyboxPSEF, command: ["ps", "-ef"])
        #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
        #expect(
            top.Processes == [
                ["1", "root", "0:00", "sleep 300"],
                ["7", "root", "0:00", "/bin/sh -c while true; do sleep 1; done"],
            ])
    }

    @Test("Docker parse refuses output without a PID column")
    func dockerParseNoPID() {
        #expect(throws: ContainerTopError.noPIDColumn) {
            try ContainerTop.parseDockerOutput("USER COMMAND\nroot sleep\n", command: ["ps", "-o", "user,args"])
        }
    }

    @Test("Docker ps_args default to -ef and split on whitespace")
    func dockerCommand() {
        #expect(ContainerTop.dockerCommand(psArgs: nil) == ["ps", "-ef"])
        #expect(ContainerTop.dockerCommand(psArgs: "") == ["ps", "-ef"])
        #expect(ContainerTop.dockerCommand(psArgs: "-o pid,args") == ["ps", "-o", "pid,args"])
    }

    @Test("Podman descriptors default to psgo's and accept repeated or comma-joined values")
    func libpodDescriptors() {
        #expect(ContainerTop.libpodDescriptors([]) == ContainerTop.libpodDefaultDescriptors)
        #expect(ContainerTop.libpodDescriptors(["user,pid", "args"]) == ["user", "pid", "args"])
        #expect(ContainerTop.libpodDescriptors(["%U", "%p"]) == ["%U", "%p"])
    }

    @Test("A podman plan puts the command line last and computes %CPU from time and etime")
    func libpodPlan() throws {
        let plan = try #require(ContainerTop.libpodPlan(descriptors: ["args", "pcpu", "comm", "user"]))
        #expect(plan.fields == ["pid", "time", "etime", "user", "comm", "args"])
        #expect(plan.command == ["ps", "-o", "pid,time,etime,user,comm,args"])
        #expect(ContainerTop.libpodPlan(descriptors: ["-ef"]) == nil)
    }

    @Test("Podman parse answers in descriptor order with podman's titles")
    func libpodParse() throws {
        let plan = try #require(ContainerTop.libpodPlan(descriptors: ContainerTop.libpodDefaultDescriptors))
        let output = """
            PID   USER     PPID  TIME  ELAPSED TT     COMMAND
                1 root         0  0:01   00:04 ?      sleep 300
               12 root         0  0:00   00:00 ?      \(plan.command.joined(separator: " "))

            """
        let top = try ContainerTop.parseLibpodOutput(output, plan: plan)
        #expect(top.Titles == ["USER", "PID", "PPID", "%CPU", "ELAPSED", "TTY", "TIME", "COMMAND"])
        #expect(top.Processes == [["root", "1", "0", "25.000", "00:04", "?", "0:01", "sleep 300"]])
    }

    @Test("ps durations parse with days and hours")
    func durations() {
        #expect(ContainerTop.seconds("00:04") == 4)
        #expect(ContainerTop.seconds("1:02:03") == 3723)
        #expect(ContainerTop.seconds("2-00:00:01") == 172_801)
        #expect(ContainerTop.seconds("x") == nil)
        #expect(ContainerTop.pcpu(time: "0:00", etime: "00:00") == "0.000")
    }
}

@Suite("ContainerTopRoute")
struct ContainerTopRouteTests {
    @Test("docker top runs ps -ef in the container and returns Titles/Processes")
    func dockerTop() async throws {
        let runner = CannedCommandRunner(stdout: busyboxPSEF)
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async throws in
                #expect(res.status == .ok)
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
                #expect(top.Processes.count == 2)
            }
        }
        #expect(runner.commands == [["ps", "-ef"]])
    }

    @Test("docker top logs moby's top event, which podman's event stream drops")
    func dockerTopEvent() async throws {
        let broadcaster = EventBroadcaster()
        let stream = await broadcaster.stream()
        let capture = Task<DockerEvent?, Never> {
            for await event in stream where event.Action == "top" { return event }
            return nil
        }
        try await withTopApp(runner: CannedCommandRunner(stdout: busyboxPSEF), broadcaster: broadcaster) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .ok)
            }
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture.cancel()
        }
        let event = await capture.value
        timeout.cancel()
        #expect(event?.Type == "container")
        #expect(event?.Actor.Attributes["name"] == "web")
        #expect(event.flatMap(LibpodEventTranslation.translate) == nil)
    }

    @Test("docker top passes ps_args through")
    func dockerTopArgs() async throws {
        let runner = CannedCommandRunner(stdout: "PID COMMAND\n1 sleep\n")
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=-o%20pid,comm") { res async in
                #expect(res.status == .ok)
            }
        }
        #expect(runner.commands == [["ps", "-o", "pid,comm"]])
    }

    @Test("top on a stopped container is a conflict")
    func notRunning() async throws {
        let runner = CannedCommandRunner(stdout: busyboxPSEF)
        try await withTopApp(status: .stopped, runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .conflict)
            }
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("An image without ps answers 500 naming ps")
    func noPS() async throws {
        let runner = CannedCommandRunner { _ in
            throw ContainerCommandError.startFailed(executable: "ps", underlying: #"vmexec error: "failed to find target executable ps""#)
        }
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("ps: executable file not found in the container"))
                #expect(res.body.string.contains("must provide ps"))
            }
        }
    }

    @Test("A failing ps answers 500 with its output")
    func psFails() async throws {
        let runner = CannedCommandRunner(stdout: "", exitCode: 1, stderr: "ps: bad -o argument 'bogus'")
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v1.51/containers/web/top?ps_args=-o%20bogus") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("bad -o argument"))
            }
        }
    }

    @Test("podman top with no descriptors runs psgo's defaults through ps -o")
    func libpodDefaults() async throws {
        let plan = try #require(ContainerTop.libpodPlan(descriptors: ContainerTop.libpodDefaultDescriptors))
        let runner = CannedCommandRunner(stdout: "PID USER PPID TIME ELAPSED TT COMMAND\n1 root 0 0:00 00:01 ? sleep 300\n")
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/top") { res async throws in
                #expect(res.status == .ok)
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Titles == ["USER", "PID", "PPID", "%CPU", "ELAPSED", "TTY", "TIME", "COMMAND"])
                #expect(top.Processes == [["root", "1", "0", "0.000", "00:01", "?", "0:00", "sleep 300"]])
            }
        }
        #expect(runner.commands == [plan.command])
    }

    @Test("podman top with descriptors and with plain ps arguments")
    func libpodDescriptorsAndPSArgs() async throws {
        let runner = CannedCommandRunner { command in
            let stdout = command == ["ps", "-ef"] ? busyboxPSEF : "PID USER COMMAND\n1 root sleep 300\n"
            return ContainerCommandOutput(exitCode: 0, stdout: stdout, stderr: "")
        }
        try await withTopApp(runner: runner) { app in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/top?ps_args=user&ps_args=pid,args") { res async throws in
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Titles == ["USER", "PID", "COMMAND"])
                #expect(top.Processes == [["root", "1", "sleep 300"]])
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/top?ps_args=-ef") { res async throws in
                let top = try res.content.decode(RESTContainerTop.self)
                #expect(top.Titles == ["PID", "USER", "TIME", "COMMAND"])
                #expect(top.Processes.count == 2)
            }
        }
        #expect(runner.commands == [["ps", "-o", "pid,user,args"], ["ps", "-ef"]])
    }
}
