import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("RenameCarryOver")
struct RenameCarryOverTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rename-carry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A bundle as Apple Container leaves it once the container has booted.
    private func bootedBundle(in root: URL, name: String, readonly: Bool = false) throws -> URL {
        let bundle = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: bundle.appendingPathComponent("rootfs.ext4"))
        try Data("log line\n".utf8).write(to: bundle.appendingPathComponent("stdio.log"))
        let rootfs = Filesystem.block(
            format: "ext4", source: bundle.appendingPathComponent("rootfs.ext4").path, destination: "/", options: readonly ? ["ro"] : [])
        try JSONEncoder().encode(rootfs).write(to: bundle.appendingPathComponent("rootfs.json"))
        return bundle
    }

    @Test("a container that ran keeps its root filesystem and log across the rebuild")
    func carriesRootfsAndLog() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBundle = try bootedBundle(in: root, name: "old", readonly: true)
        let staging = root.appendingPathComponent("staging")

        let carried = try #require(try RenameCarryOver.stage(from: oldBundle, into: staging))
        #expect(!FileManager.default.fileExists(atPath: oldBundle.appendingPathComponent("rootfs.ext4").path), "the delete must not take it")

        let newBundle = root.appendingPathComponent("new")
        let options = carried.createOptions(autoRemove: false, bundle: newBundle)
        let override = try #require(options.rootFsOverride)
        #expect(override.source == newBundle.appendingPathComponent("rootfs.ext4").path)
        #expect(override.destination == "/")
        #expect(override.options.contains("ro"), "a read-only root filesystem stays read-only")

        try carried.land(in: newBundle)
        #expect(try String(contentsOf: newBundle.appendingPathComponent("rootfs.ext4"), encoding: .utf8) == "disk")
        #expect(try String(contentsOf: newBundle.appendingPathComponent("stdio.log"), encoding: .utf8) == "log line\n")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("a renamed container that has not booted since is renamed again from its runtime configuration")
    func renamedAgainBeforeBooting() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(try RenameCarryOver.stage(from: try bootedBundle(in: root, name: "a"), into: root.appendingPathComponent("s1")))
        let middle = root.appendingPathComponent("b")
        let options = first.createOptions(autoRemove: false, bundle: middle)
        try first.land(in: middle)
        // What the create leaves behind: no rootfs.json until the first boot.
        let runtime = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(options))
        try JSONSerialization.data(withJSONObject: ["path": middle.path, "options": runtime])
            .write(to: middle.appendingPathComponent("runtime-configuration.json"))

        let second = try #require(try RenameCarryOver.stage(from: middle, into: root.appendingPathComponent("s2")))
        let last = root.appendingPathComponent("c")
        #expect(second.createOptions(autoRemove: false, bundle: last).rootFsOverride?.source == last.appendingPathComponent("rootfs.ext4").path)
        try second.land(in: last)
        #expect(try String(contentsOf: last.appendingPathComponent("rootfs.ext4"), encoding: .utf8) == "disk")
    }

    @Test("a container that never ran has nothing to carry")
    func neverStartedCarriesNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("created")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        #expect(try RenameCarryOver.stage(from: bundle, into: root.appendingPathComponent("staging")) == nil)
    }

    @Test("a renamed container that had run reads as exited with its last start time, not created")
    func renamedContainerKeepsItsStartTime() {
        let process = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        var configuration = ContainerConfiguration(id: "renamed", image: image, process: process)
        let fresh = ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])
        #expect(fresh.mobyState == "created")

        configuration.labels[ContainerSnapshot.startedAtLabel] = "1000.5"
        let renamed = ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])
        #expect(renamed.mobyState == "exited")
        #expect(renamed.lastStartedDate == Date(timeIntervalSince1970: 1000.5))
    }
}
