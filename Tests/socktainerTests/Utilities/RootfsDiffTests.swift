import ContainerizationEXT4
import Foundation
import SystemPackage
import Testing

@testable import socktainer

@Suite("RootfsDiff")
struct RootfsDiffTests {
    private static let image: [DiffEntry] = [
        .dir("/bin"), .file("/bin/sh", "shell"),
        .dir("/etc"), .file("/etc/passwd", "root:x:0:0"),
        .dir("/tmp"),
        .dir("/var"), .dir("/var/log"), .file("/var/log/old.log", "old"),
        .file("/keep.txt", "keep"),
    ]

    @Test("an untouched clone has no changes")
    func identicalHasNoChanges() throws {
        let fixture = try DiffFixture()
        defer { fixture.cleanUp() }

        let changes = try RootfsDiff.changes(base: fixture.reader(Self.image), container: fixture.reader(Self.image))

        #expect(changes.isEmpty)
    }

    @Test("adds, deletes and modifications are reported like docker diff, parents first")
    func reportsChanges() throws {
        let fixture = try DiffFixture()
        defer { fixture.cleanUp() }
        let container: [DiffEntry] = [
            .dir("/bin"), .file("/bin/sh", "shell"),
            .dir("/etc"), .file("/etc/passwd", "root:x:0:0\nio:x:1000:1000", Date(timeIntervalSince1970: 1_800_000_000)),
            .dir("/tmp"), .file("/tmp/new.txt", "new"),
            .dir("/var"),
            .file("/keep.txt", "keep"),
            .dir("/newdir"), .dir("/newdir/a"), .file("/newdir/a/b.txt", "b"),
        ]

        let changes = try RootfsDiff.changes(base: fixture.reader(Self.image), container: fixture.reader(container))

        #expect(
            changes == [
                .init(path: "/etc", kind: .modified),
                .init(path: "/etc/passwd", kind: .modified),
                .init(path: "/newdir", kind: .added),
                .init(path: "/newdir/a", kind: .added),
                .init(path: "/newdir/a/b.txt", kind: .added),
                .init(path: "/tmp", kind: .modified),
                .init(path: "/tmp/new.txt", kind: .added),
                .init(path: "/var", kind: .modified),
                .init(path: "/var/log", kind: .deleted),
            ])
    }

    @Test("files the runtime writes at start are not changes, as moby's init layer hides them")
    func runtimeManagedFilesIgnored() throws {
        let fixture = try DiffFixture()
        defer { fixture.cleanUp() }
        let container =
            Self.image + [
                .file("/etc/hosts", "127.0.0.1 localhost"), .file("/etc/hostname", "web"), .file("/etc/resolv.conf", "nameserver 1.1.1.1"),
            ]

        let changes = try RootfsDiff.changes(base: fixture.reader(Self.image), container: fixture.reader(container))

        #expect(changes.isEmpty)
    }

    @Test("a chmod alone is a modification")
    func permissionChangeIsModified() throws {
        let fixture = try DiffFixture()
        defer { fixture.cleanUp() }
        var container = Self.image
        container[container.count - 1] = .file("/keep.txt", "keep", mode: 0o600)

        let changes = try RootfsDiff.changes(base: fixture.reader(Self.image), container: fixture.reader(container))

        #expect(changes == [.init(path: "/keep.txt", kind: .modified)])
    }

    @Test("a file replaced by a directory is modified and its contents added")
    func fileReplacedByDirectory() throws {
        let fixture = try DiffFixture()
        defer { fixture.cleanUp() }
        var container = Self.image
        container[container.count - 1] = .dir("/keep.txt")
        container.append(.file("/keep.txt/inner", "x"))

        let changes = try RootfsDiff.changes(base: fixture.reader(Self.image), container: fixture.reader(container))

        #expect(changes == [.init(path: "/keep.txt", kind: .modified), .init(path: "/keep.txt/inner", kind: .added)])
    }
}

private enum DiffEntry {
    case file(String, String, Date = Date(timeIntervalSince1970: 1_700_000_000), mode: UInt16 = 0o644)
    case dir(String, mode: UInt16 = 0o755)
}

private struct DiffFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rootfs-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Formats a fresh ext4 holding `entries`, with fixed timestamps so equal entries in
    /// two images carry equal metadata, as an image snapshot and its clone do.
    func reader(_ entries: [DiffEntry]) throws -> EXT4.EXT4Reader {
        let device = directory.appendingPathComponent("\(UUID().uuidString).ext4")
        let formatter = try EXT4.Formatter(FilePath(device.path))
        for entry in entries {
            switch entry {
            case .dir(let path, let mode):
                let ts = FileTimestamps(access: nil, modification: Date(timeIntervalSince1970: 1_700_000_000), creation: nil)
                try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFDIR, mode), ts: ts)
            case .file(let path, let contents, let modified, let mode):
                let stream = InputStream(data: Data(contents.utf8))
                stream.open()
                let ts = FileTimestamps(access: nil, modification: modified, creation: nil)
                try formatter.create(path: FilePath(path), mode: EXT4.Inode.Mode(.S_IFREG, mode), ts: ts, buf: stream)
            }
        }
        try formatter.close()
        return try EXT4.EXT4Reader(blockDevice: FilePath(device.path))
    }
}
