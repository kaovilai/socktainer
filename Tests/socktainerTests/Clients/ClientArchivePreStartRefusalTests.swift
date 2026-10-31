import Testing

@testable import socktainer

@Suite("ClientArchiveService.preStartRefusal")
struct ClientArchivePreStartRefusalTests {
    private typealias Plan = ClientArchiveService.ArchiveEntryPlan

    private func dir(_ path: String) -> Plan { Plan(relativePath: path, guestPath: path, kind: .directory, mode: 0o755) }
    private func file(_ path: String) -> Plan { Plan(relativePath: path, guestPath: path, kind: .file, mode: 0o644) }

    @Test("buildx's buildkitd.toml upload (a directory holding one file) can be staged")
    func buildxConfigDirectory() {
        let plan = [dir("/etc/buildkit"), file("/etc/buildkit/buildkitd.toml")]
        #expect(ClientArchiveService.preStartRefusal(plan: plan, containerId: "c") == nil)
    }

    @Test("a trailing slash on the directory entry still matches its file")
    func trailingSlash() {
        let plan = [dir("/etc/buildkit/"), file("/etc/buildkit/buildkitd.toml")]
        #expect(ClientArchiveService.preStartRefusal(plan: plan, containerId: "c") == nil)
    }

    @Test("an empty directory, or one whose files are elsewhere, is refused")
    func emptyDirectoryRefused() {
        #expect(ClientArchiveService.preStartRefusal(plan: [dir("/etc/empty")], containerId: "c")?.contains("directory") == true)
        let plan = [dir("/etc/a"), file("/etc/b/x")]
        #expect(ClientArchiveService.preStartRefusal(plan: plan, containerId: "c")?.contains("directory") == true)
    }

    @Test("symlinks are refused")
    func symlinkRefused() {
        let plan = [Plan(relativePath: "l", guestPath: "/l", kind: .symlink(target: "/x"), mode: 0o777)]
        #expect(ClientArchiveService.preStartRefusal(plan: plan, containerId: "c")?.contains("symlink") == true)
    }
}
