import ContainerAPIClient
import ContainerResource
import ContainerizationEXT4
import Foundation
import Logging
import SystemPackage
import Testing

@testable import socktainer

@Suite("Copy-up into bind-backed volumes")
struct BindVolumeCopyUpTests {

    /// An app-support tree holding one container whose image rootfs carries `/data/conf/app.conf`
    /// (mode 0640) and a `/data/current` symlink.
    private static func fixture() throws -> (appSupport: URL, container: ContainerSnapshot) {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("po-copyup-\(UUID().uuidString)")
        let snapshot = appSupport.appendingPathComponent("snapshots/abc/snapshot")
        try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = try EXT4.Formatter(FilePath(snapshot.path))
        let stream = InputStream(data: Data("key=value\n".utf8))
        stream.open()
        try formatter.create(
            path: FilePath("/data/conf/app.conf"), mode: EXT4.Inode.Mode(.S_IFREG, 0o640), buf: stream, recursion: true)
        stream.close()
        try formatter.create(
            path: FilePath("/data/current"), link: FilePath("conf"), mode: EXT4.Inode.Mode(.S_IFLNK, 0o777), recursion: true)
        try formatter.close()

        let containerDir = appSupport.appendingPathComponent("containers/po-copyup")
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)
        try Data(#"{"containerRootFilesystem":{"source":"\#(snapshot.path)"}}"#.utf8)
            .write(to: containerDir.appendingPathComponent("runtime-configuration.json"))
        let container = try makeContainerSnapshot(nativeId: "po-copyup", networks: [], labels: [:])
        return (appSupport, container)
    }

    @Test("an empty host directory takes the image's content at the mount path")
    func copiesIntoEmptyDirectory() throws {
        let (appSupport, container) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let host = appSupport.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)

        ContainerCreateRoute.populateEmptyBindVolumes(
            [(source: host.path, destination: "/data")], for: container, appSupport: appSupport, logger: Logger(label: "test"))

        let conf = host.appendingPathComponent("conf/app.conf")
        #expect(try String(contentsOf: conf, encoding: .utf8) == "key=value\n")
        let mode = try FileManager.default.attributesOfItem(atPath: conf.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: host.appendingPathComponent("current").path) == "conf")
    }

    @Test("a host directory that already has content is left alone")
    func leavesNonEmptyDirectory() throws {
        let (appSupport, container) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let host = appSupport.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: host.appendingPathComponent("existing"))

        ContainerCreateRoute.populateEmptyBindVolumes(
            [(source: host.path, destination: "/data")], for: container, appSupport: appSupport, logger: Logger(label: "test"))

        #expect(try FileManager.default.contentsOfDirectory(atPath: host.path) == ["existing"])
    }
}
