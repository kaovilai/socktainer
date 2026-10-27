import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// podman's `exec -t` creates the exec with `Tty: true` but starts it with `Tty: false` whenever
/// the client's own stdin is not a terminal; real podman keeps the session's setting.
@Suite("Libpod exec start keeps the session's terminal setting")
struct LibpodExecStartTtyTests {
    @Test("A libpod start runs a tty exec on a pty even when its body says Tty: false")
    func libpodIgnoresStartBodyTty() {
        #expect(ExecRoute.startTty(requested: false, configured: true, sessionTty: true))
        #expect(!ExecRoute.startTty(requested: true, configured: false, sessionTty: true))
    }

    @Test("A Docker start still honours the body's Tty, falling back to the exec's")
    func dockerHonoursStartBodyTty() {
        #expect(!ExecRoute.startTty(requested: false, configured: true, sessionTty: false))
        #expect(ExecRoute.startTty(requested: nil, configured: true, sessionTty: false))
    }

    @Test("The libpod start route marks the request to use the session's terminal setting")
    func libpodRouteMarksRequest() async throws {
        try await withApp(configure: { _ in }) { app in
            let req = Request(application: app, method: .POST, url: "/libpod/exec/x/start", on: app.eventLoopGroup.next())
            let prepared = LibpodExecStartRoute.prepare(req)
            #expect(prepared.storage[ExecStartUsesSessionTtyKey.self] == true)
            #expect(prepared.headers.contentType == .json)
        }
    }
}
