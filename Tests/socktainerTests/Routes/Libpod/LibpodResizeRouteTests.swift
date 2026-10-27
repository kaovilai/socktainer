import ContainerAPIClient
import ContainerResource
import ContainerizationOS
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// podman resizes `run -it`/`attach` and `exec -it` terminals through the libpod resize paths;
/// without them the container's terminal stays 0x0 and `stty size` fails.
@Suite("Libpod resize routes")
struct LibpodResizeRouteTests {

    @Test("libpod container resize reaches the container's process")
    func containerResize() async throws {
        let nativeId = "libpod-resize-\(Int.random(in: 10000...99999))"
        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        let process = SizeRecordingProcess()
        await ProcessRegistry.shared.set(id: nativeId, process: process)
        defer { Task { await ProcessRegistry.shared.remove(id: nativeId) } }

        try await withResizeApp(client: StaticSnapshotClientMock(snapshot: snapshot)) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/\(nativeId)/resize?h=40&w=120&running=true") { res async in
                #expect(res.status == .ok)
            }
        }
        let size = await process.sizes.last
        #expect(size?.height == 40)
        #expect(size?.width == 120)
    }

    @Test("a resize before the container starts applies once its process exists")
    func resizeBeforeStart() async throws {
        let nativeId = "libpod-resize-early-\(Int.random(in: 10000...99999))"
        let snapshot = try makeContainerSnapshot(nativeId: nativeId, ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        defer { Task { await ProcessRegistry.shared.remove(id: nativeId) } }

        try await withResizeApp(client: StaticSnapshotClientMock(snapshot: snapshot)) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/containers/\(nativeId)/resize?h=30&w=90") { res async in
                #expect(res.status == .ok)
            }
        }
        let process = SizeRecordingProcess()
        await ProcessRegistry.shared.set(id: nativeId, process: process)
        var size: ContainerizationOS.Terminal.Size?
        for _ in 0..<100 where size == nil {
            size = await process.sizes.last
            if size == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(size?.height == 30)
        #expect(size?.width == 90)
    }

    @Test("libpod exec resize reaches the exec process, and an unknown session is 404")
    func execResize() async throws {
        let execId = await ExecManager.shared.create(
            config: ExecManager.ExecConfig(
                containerId: "libpod-resize-exec-ctr", cmd: ["sh"],
                attachStdin: true, attachStdout: true, attachStderr: true,
                tty: true, detach: false, env: [], user: nil, workingDir: nil
            ))
        let process = SizeRecordingProcess()
        await ProcessRegistry.shared.set(id: execId, process: process)
        defer {
            Task {
                await ProcessRegistry.shared.remove(id: execId)
                await ExecManager.shared.remove(id: execId)
            }
        }

        let snapshot = try makeContainerSnapshot(
            nativeId: "libpod-resize-exec-ctr", ip: "192.168.65.2", network: "bridge", labels: [:], status: .running)
        try await withResizeApp(client: StaticSnapshotClientMock(snapshot: snapshot)) { app in
            try await app.testing().test(.POST, "/v1.51/libpod/exec/\(execId)/resize?h=50&w=132") { res async in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.POST, "/v1.51/libpod/exec/no-such-session/resize?h=50&w=132") { res async in
                #expect(res.status == .notFound)
            }
        }
        let size = await process.sizes.last
        #expect(size?.height == 50)
        #expect(size?.width == 132)
    }

    @Test("podman's exec start h/w is the initial console size when ConsoleSize is absent")
    func execStartSize() {
        #expect(ExecRoute.requestedConsoleSize(nil, h: 30, w: 100) == [30, 100])
        #expect(ExecRoute.requestedConsoleSize([24, 80], h: 30, w: 100) == [24, 80])
        #expect(ExecRoute.requestedConsoleSize(nil, h: 30, w: nil) == nil)
    }
}

private func withResizeApp(client: ClientContainerProtocol, test: @escaping (Application) async throws -> Void) async throws {
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        try app.register(collection: LibpodResizeRoute(client: client))
        try await test(app)
    }
}

private actor SizeRecordingProcess: ClientProcess {
    nonisolated let id = "libpod-resize-test-process"
    private(set) var sizes: [ContainerizationOS.Terminal.Size] = []
    func start() async throws {}
    func resize(_ size: ContainerizationOS.Terminal.Size) async throws { sizes.append(size) }
    func kill(_ signal: Int32) async throws {}
    func wait() async throws -> Int32 { 0 }
}
