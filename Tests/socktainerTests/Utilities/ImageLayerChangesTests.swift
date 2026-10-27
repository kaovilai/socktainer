import ContainerizationArchive
import Foundation
import Logging
import Testing

@testable import socktainer

@Suite("ImageLayerChanges")
struct ImageLayerChangesTests {

    // MARK: - Helpers

    private enum Item {
        case dir(String)
        case file(String, String)
        case symlink(String, String)
        case whiteout(String)
    }

    private static func writeTar(_ items: [Item], filter: Filter = .none, to url: URL) throws {
        let writer = try ArchiveWriter(format: .paxRestricted, filter: filter, file: url)
        for item in items {
            let entry = WriteEntry()
            entry.owner = 0
            entry.group = 0
            entry.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
            switch item {
            case .dir(let path):
                entry.path = path
                entry.fileType = .directory
                entry.permissions = 0o755
                try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
            case .file(let path, let contents):
                entry.path = path
                entry.fileType = .regular
                entry.permissions = 0o644
                entry.size = Int64(contents.utf8.count)
                try writer.writeEntry(entry: entry, data: Data(contents.utf8))
            case .symlink(let path, let target):
                entry.path = path
                entry.fileType = .symbolicLink
                entry.permissions = 0o777
                entry.symlinkTarget = target
                try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
            case .whiteout(let path):
                entry.path = path
                entry.fileType = .regular
                entry.permissions = 0o644
                entry.size = 0
                try writer.writeEntry(entry: entry, data: Data())
            }
        }
        try writer.finishEncoding()
    }

    private static func entries(of url: URL) throws -> [(path: String, contents: String)] {
        let reader = try ArchiveReader(file: url)
        return reader.map { entry, data in (entry.path ?? "", String(decoding: data, as: UTF8.self)) }
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layer-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func info(dir: Bool = false, size: Int64 = 0, mode: UInt32 = 0o644) -> ImageLayerChanges.EntryInfo {
        ImageLayerChanges.EntryInfo(
            isDirectory: dir, mode: dir ? 0o755 : mode, uid: 0, gid: 0, size: size, modified: Date(timeIntervalSince1970: 0), linkTarget: nil)
    }

    private static func change(_ path: String, _ kind: RootfsDiff.Kind) -> RootfsDiff.Change {
        RootfsDiff.Change(path: path, kind: kind)
    }

    // MARK: - Naming

    @Test("tar entry names normalize to absolute paths")
    func normalizesNames() {
        #expect(ImageLayerChanges.normalize("./etc/passwd") == "/etc/passwd")
        #expect(ImageLayerChanges.normalize("etc/") == "/etc")
        #expect(ImageLayerChanges.normalize("/usr/bin") == "/usr/bin")
        #expect(ImageLayerChanges.normalize("./") == "/")
    }

    @Test("a deleted path becomes a .wh. entry beside it")
    func whiteoutNames() {
        #expect(ImageLayerChanges.whiteoutEntry(for: "/etc/motd") == "etc/.wh.motd")
        #expect(ImageLayerChanges.whiteoutEntry(for: "/tmpfile") == ".wh.tmpfile")
        #expect(ImageLayerChanges.whiteoutEntry(for: "/a/b/c") == "a/b/.wh.c")
    }

    // MARK: - docker commit

    @Test("the change layer holds whiteouts for deletions and only the changed entries, parents first")
    func writesChangeLayer() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("rootfs.tar")
        try Self.writeTar(
            [
                .dir("etc"), .file("etc/keep.conf", "unchanged"), .file("etc/new.conf", "written"),
                .dir("usr"), .dir("usr/bin"), .symlink("usr/bin/sh", "busybox"), .file("usr/bin/busybox", "binary"),
            ], to: full)

        let output = dir.appendingPathComponent("layer.tar")
        try ImageLayerChanges.writeChangeLayer(
            changes: [
                Self.change("/etc", .modified), Self.change("/etc/motd", .deleted), Self.change("/etc/new.conf", .added),
                Self.change("/usr/bin/sh", .added), Self.change("/var", .deleted),
            ],
            fullRootfsTar: full, to: output)

        let written = try Self.entries(of: output)
        #expect(written.map { ImageLayerChanges.normalize($0.path) } == ["/etc/.wh.motd", "/.wh.var", "/etc", "/etc/new.conf", "/usr/bin/sh"])
        #expect(written.first { $0.path == "etc/new.conf" }?.contents == "written")
        #expect(written.first { $0.path == "etc/.wh.motd" }?.contents == "")
    }

    @Test("a commit that only deletes needs no export of the rootfs")
    func deletionOnlyLayer() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("layer.tar")
        try ImageLayerChanges.writeChangeLayer(
            changes: [Self.change("/etc/motd", .deleted)], fullRootfsTar: dir.appendingPathComponent("absent.tar"), to: output)
        #expect(try Self.entries(of: output).map(\.path) == ["etc/.wh.motd"])
    }

    @Test("the snapshot path names the manifest the rootfs came from")
    func snapshotManifestDigest() {
        let hex = String(repeating: "ab", count: 32)
        let snapshot = URL(fileURLWithPath: "/data/snapshots/\(hex)/snapshot")
        #expect(ClientArchiveService.manifestDigest(ofSnapshot: snapshot) == "sha256:\(hex)")
        #expect(ClientArchiveService.manifestDigest(ofSnapshot: URL(fileURLWithPath: "/data/snapshots/latest/snapshot")) == nil)
    }

    @Test("a layered commit keeps the base layers and appends one layer, diff_id and history entry")
    func buildsLayeredLayout() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let contentRoot = dir.appendingPathComponent("content")
        let storeBlobs = contentRoot.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: storeBlobs, withIntermediateDirectories: true)
        let baseLayer = Data("base-layer-bytes".utf8)
        let baseLayerHex = baseLayer.sha256Hex()
        try baseLayer.write(to: storeBlobs.appendingPathComponent(baseLayerHex))

        let baseConfig = Data(
            #"{"architecture":"arm64","os":"linux","config":{"Cmd":["/bin/sh"]},"rootfs":{"type":"layers","diff_ids":["sha256:basediff"]},"history":[{"created_by":"ADD rootfs"}]}"#
                .utf8)
        let baseManifest = Data(
            #"{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:cfg","size":1},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"sha256:\#(baseLayerHex)","size":\#(baseLayer.count)}]}"#
                .utf8)
        let base = CommitBase(manifestDigest: "sha256:basemanifest", manifest: baseManifest, config: baseConfig, contentRoot: contentRoot)

        let changeTar = dir.appendingPathComponent("changes.tar")
        try Self.writeTar([.file("hello.txt", "hi"), .whiteout("etc/.wh.motd")], to: changeTar)

        let layout = dir.appendingPathComponent("layout")
        let manifestHex = try ContainerImageUtility.buildLayeredOCILayout(
            changeTarPath: changeTar, base: base, ociLayoutPath: layout, configDict: ["Cmd": ["/bin/true"]], message: "snap",
            author: "me", reference: "docker.io/library/io-layered:latest", logger: Logger(label: "test"))

        let blobs = layout.appendingPathComponent("blobs/sha256")
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: blobs.appendingPathComponent(manifestHex))) as? [String: Any])
        let layers = try #require(manifest["layers"] as? [[String: Any]])
        #expect(layers.count == 2)
        #expect(layers[0]["digest"] as? String == "sha256:\(baseLayerHex)")
        #expect(layers[1]["mediaType"] as? String == "application/vnd.oci.image.layer.v1.tar+gzip")
        for layer in layers {
            let hex = try #require((layer["digest"] as? String)?.dropFirst("sha256:".count))
            #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(String(hex)).path))
        }

        let configHex = try #require(((manifest["config"] as? [String: Any])?["digest"] as? String)?.dropFirst("sha256:".count))
        let config = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: blobs.appendingPathComponent(String(configHex)))) as? [String: Any])
        let diffIds = try #require((config["rootfs"] as? [String: Any])?["diff_ids"] as? [String])
        #expect(diffIds.count == 2)
        #expect(diffIds.first == "sha256:basediff")
        let history = try #require(config["history"] as? [[String: Any]])
        #expect(history.count == 2)
        #expect(history.last?["comment"] as? String == "snap")
        #expect(history.last?["author"] as? String == "me")
        #expect((config["config"] as? [String: Any])?["Cmd"] as? [String] == ["/bin/true"])
        #expect(config["architecture"] as? String == "arm64")
    }

    @Test("a Docker schema 2 base keeps Docker media types")
    func keepsDockerMediaTypes() throws {
        let dir = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = CommitBase(
            manifestDigest: "sha256:m",
            manifest: Data(#"{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[]}"#.utf8),
            config: Data(#"{"config":{}}"#.utf8), contentRoot: dir)
        let changeTar = dir.appendingPathComponent("changes.tar")
        try Self.writeTar([.file("a", "b")], to: changeTar)
        let layout = dir.appendingPathComponent("layout")
        let manifestHex = try ContainerImageUtility.buildLayeredOCILayout(
            changeTarPath: changeTar, base: base, ociLayoutPath: layout, configDict: [:], message: nil, author: nil, reference: nil,
            logger: Logger(label: "test"))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appendingPathComponent("blobs/sha256/\(manifestHex)")))
                as? [String: Any])
        #expect(manifest["mediaType"] as? String == ContainerImageUtility.dockerManifestMediaType)
        #expect((manifest["layers"] as? [[String: Any]])?.first?["mediaType"] as? String == "application/vnd.docker.image.rootfs.diff.tar.gzip")
    }
}
