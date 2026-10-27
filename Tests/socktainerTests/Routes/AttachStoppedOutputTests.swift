import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// The output-only attach to a stopped container (what `podman run` without `-i` and
/// `docker run` without `-i` use) streams the container's output once `/start` has booted it, and the
/// upgraded connection is closed only after this returns. If it never returned the connection would
/// stay open, and podman, which waits for EOF, would hang after the container exits.
@Suite("ContainerAttachRoute.pumpStoppedOutput")
struct AttachStoppedOutputTests {
    private actor Collected {
        private(set) var buffers: [ByteBuffer] = []
        func add(_ buffer: ByteBuffer) { buffers.append(buffer) }
    }

    private struct FakeProcess: ClientProcess {
        let id = "init"
        let code: Int32
        func start() async throws {}
        func resize(_ size: ContainerizationOS.Terminal.Size) async throws {}
        func kill(_ signal: Int32) async throws {}
        func wait() async throws -> Int32 { code }
    }

    private func snapshot(id: String) -> ContainerSnapshot {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerSnapshot(configuration: ContainerConfiguration(id: id, image: image, process: process), status: .stopped, networks: [])
    }

    @Test("stdout and stderr are framed, and the pump returns once the process exited and both pipes drained")
    func pumpsFramesThenReturns() async throws {
        let pipes = try #require(StdioPipes.make(stdin: true, stdout: true, stderr: true))
        defer { pipes.closeAll() }
        // The container's side: write output, then close the write ends as exit does.
        try pipes.stdout?.write.write(contentsOf: Data("out-text".utf8))
        try pipes.stderr?.write.write(contentsOf: Data("err-text".utf8))
        try pipes.stdout?.write.close()
        try pipes.stderr?.write.close()

        let collected = Collected()
        try await withApp(configure: { _ in }) { app in
            let req = Request(application: app, on: app.eventLoopGroup.next())
            await ContainerAttachRoute.pumpStoppedOutput(
                process: FakeProcess(code: 5), pipes: pipes, container: snapshot(id: "attach-pump-test"), hexId: "attach-pump-test-hex",
                isTTY: false, stderrOnly: false, req: req, write: { await collected.add($0) })
        }

        let frames = await collected.buffers.map { Array($0.readableBytesView) }
        let joined = frames.flatMap { $0 }
        // 8-byte Docker header: stream type (1 stdout / 2 stderr), 3 zero bytes, big-endian length.
        #expect(frames.contains { $0.first == 1 && $0.count == 8 + "out-text".count && String(decoding: $0.dropFirst(8), as: UTF8.self) == "out-text" })
        #expect(frames.contains { $0.first == 2 && String(decoding: $0.dropFirst(8), as: UTF8.self) == "err-text" })
        #expect(joined.count == 2 * 8 + "out-text".count + "err-text".count)
        #expect(await ContainerExitCodeStore.shared.get(id: "attach-pump-test") == 5)
    }
}
