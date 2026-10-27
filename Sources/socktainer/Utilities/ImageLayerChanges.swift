import ContainerizationArchive
import Foundation

/// Layer-level filesystem changes: the layer `docker commit` adds on top of a container's
/// image, and the change list `podman image diff` reads back out of an image's layers.
///
/// Layers use the OCI changeset format: an added or modified path is a regular tar entry,
/// and a deleted path `dir/name` is an empty `dir/.wh.name` entry (a whiteout). A
/// `dir/.wh..wh..opq` entry (an opaque whiteout) hides everything lower layers put in `dir`.
enum ImageLayerChanges {
    static let whiteoutPrefix = ".wh."
    static let opaqueWhiteout = ".wh..wh..opq"

    /// A tar entry name as an absolute path: `./etc/x`, `etc/x/` and `/etc/x` are all `/etc/x`.
    static func normalize(_ name: String) -> String {
        let components = name.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        return "/" + components.joined(separator: "/")
    }

    /// The whiteout entry that deletes `path` (`/a/b` → `a/.wh.b`).
    static func whiteoutEntry(for path: String) -> String {
        var components = normalize(path).split(separator: "/").map(String.init)
        let base = components.removeLast()
        return (components + [whiteoutPrefix + base]).joined(separator: "/")
    }

    // MARK: - docker commit

    /// Writes the layer holding a container's `changes` (`RootfsDiff`) to `output`: a
    /// whiteout for each deleted path, then the entry of each added or modified path,
    /// copied from `fullRootfsTar` (the container's whole filesystem, as `docker export`
    /// writes it) in that archive's order, so a directory precedes its contents.
    ///
    /// A modified directory carries only its own entry; its unchanged contents stay in the
    /// lower layers.
    static func writeChangeLayer(changes: [RootfsDiff.Change], fullRootfsTar: URL, to output: URL) throws {
        let kept = Set(changes.filter { $0.kind != .deleted }.map(\.path))
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: output)

        for change in changes where change.kind == .deleted {
            let entry = WriteEntry()
            entry.path = whiteoutEntry(for: change.path)
            entry.fileType = .regular
            entry.permissions = 0o644
            entry.size = 0
            entry.owner = 0
            entry.group = 0
            entry.modificationDate = Date()
            try writer.writeEntry(entry: entry, data: Data())
        }

        if !kept.isEmpty {
            let reader = try ArchiveReader(file: fullRootfsTar)
            for (entry, data) in reader {
                guard let name = entry.path, kept.contains(normalize(name)) else { continue }
                if entry.fileType == .regular, entry.hardlink == nil {
                    try writer.writeEntry(entry: entry, data: data)
                } else {
                    try writer.writeEntry(entry: entry, data: nil as UnsafeRawBufferPointer?)
                }
            }
            try reader.throwIfStreamFailed()
        }
        try writer.finishEncoding()
    }

    // MARK: - podman image diff

    /// What a layer entry says about a path, enough to tell whether it changed.
    struct EntryInfo: Equatable, Sendable {
        let isDirectory: Bool
        let mode: UInt32
        let uid: UInt32
        let gid: UInt32
        let size: Int64
        let modified: Date?
        let linkTarget: String?

        /// moby `ChangesDirs`: type, permissions or owner, and — except for a directory,
        /// whose size says nothing — size, modification time or link target.
        func differs(from other: EntryInfo) -> Bool {
            if isDirectory != other.isDirectory || mode != other.mode || uid != other.uid || gid != other.gid {
                return true
            }
            if isDirectory {
                return false
            }
            return size != other.size || modified != other.modified || linkTarget != other.linkTarget
        }
    }

    enum LayerEntry: Equatable, Sendable {
        /// `path` was deleted.
        case whiteout(String)
        /// Lower layers' contents of the directory `path` are hidden.
        case opaque(String)
        /// `path` was added or replaced.
        case entry(String, EntryInfo)
    }

    /// The entries of one layer blob (plain, gzip or zstd tar), in archive order.
    static func readLayer(at url: URL) throws -> [LayerEntry] {
        let reader = try ArchiveReader(file: url)
        var entries: [LayerEntry] = []
        for (entry, _) in reader.makeStreamingIterator() {
            guard let name = entry.path else { continue }
            let path = normalize(name)
            guard path != "/" else { continue }
            let base = path[path.index(after: path.lastIndex(of: "/")!)...]
            let parent = String(path[..<path.lastIndex(of: "/")!])
            if base == opaqueWhiteout {
                entries.append(.opaque(parent.isEmpty ? "/" : parent))
            } else if base.hasPrefix(whiteoutPrefix) {
                entries.append(.whiteout(parent + "/" + base.dropFirst(whiteoutPrefix.count)))
            } else {
                let info = EntryInfo(
                    isDirectory: entry.fileType == .directory,
                    mode: UInt32(entry.permissions) & 0o7777,
                    uid: UInt32(entry.owner ?? 0),
                    gid: UInt32(entry.group ?? 0),
                    size: entry.size ?? 0,
                    modified: entry.modificationDate,
                    linkTarget: entry.symlinkTarget ?? entry.hardlink.map(normalize)
                )
                entries.append(.entry(path, info))
            }
        }
        try reader.throwIfStreamFailed()
        return entries
    }

    /// Applies one layer on top of `tree` (the filesystem the lower layers build).
    static func apply(_ layer: [LayerEntry], to tree: inout [String: EntryInfo]) {
        for entry in layer {
            switch entry {
            case .whiteout(let path):
                tree[path] = nil
                removeDescendants(of: path, from: &tree)
            case .opaque(let path):
                removeDescendants(of: path, from: &tree)
            case .entry(let path, let info):
                if !info.isDirectory, tree[path]?.isDirectory == true {
                    removeDescendants(of: path, from: &tree)
                }
                tree[path] = info
            }
        }
    }

    static func tree(of layers: [[LayerEntry]]) -> [String: EntryInfo] {
        var tree: [String: EntryInfo] = [:]
        for layer in layers {
            apply(layer, to: &tree)
        }
        return tree
    }

    private static func removeDescendants(of path: String, from tree: inout [String: EntryInfo]) {
        let prefix = path == "/" ? "/" : path + "/"
        for key in tree.keys where key.hasPrefix(prefix) {
            tree[key] = nil
        }
    }

    /// `podman image diff IMAGE`: the changes the image's top layer makes over the layers
    /// below it (containers/storage's overlay `Changes`): a whiteout is a deletion, an entry
    /// for a path the lower layers already have is a modification, any other entry is an
    /// addition, and the directory holding an addition or deletion is modified.
    static func topLayerChanges(_ top: [LayerEntry], lower: [String: EntryInfo]) -> [RootfsDiff.Change] {
        var kinds: [String: RootfsDiff.Kind] = [:]
        func record(_ path: String, _ kind: RootfsDiff.Kind) {
            if kinds[path] == nil { kinds[path] = kind }
        }
        func touchParent(of path: String) {
            let parent = parentPath(of: path)
            if parent != "/", lower[parent] != nil { record(parent, .modified) }
        }
        for entry in top {
            switch entry {
            case .whiteout(let path):
                guard lower[path] != nil else { continue }
                record(path, .deleted)
                touchParent(of: path)
            case .opaque(let path):
                if path != "/", lower[path] != nil { record(path, .modified) }
            case .entry(let path, _):
                if lower[path] != nil {
                    record(path, .modified)
                } else {
                    record(path, .added)
                    touchParent(of: path)
                }
            }
        }
        return sorted(kinds)
    }

    /// `podman image diff IMAGE PARENT`: how `new`'s filesystem differs from `old`'s, with
    /// `RootfsDiff`'s rules — everything under an added directory is added, only the top of
    /// a deleted tree is listed, and a directory whose contents changed is modified.
    static func treeChanges(from old: [String: EntryInfo], to new: [String: EntryInfo]) -> [RootfsDiff.Change] {
        var kinds: [String: RootfsDiff.Kind] = [:]
        for (path, info) in new {
            if let previous = old[path] {
                if info.differs(from: previous) { kinds[path] = .modified }
            } else {
                kinds[path] = .added
            }
        }
        for path in old.keys where new[path] == nil {
            let parent = parentPath(of: path)
            if parent != "/", old[parent] != nil, new[parent] == nil || new[parent]?.isDirectory == false {
                continue
            }
            kinds[path] = .deleted
        }
        for path in Array(kinds.keys) {
            var ancestor = parentPath(of: path)
            while ancestor != "/" {
                if old[ancestor]?.isDirectory == true, new[ancestor]?.isDirectory == true, kinds[ancestor] == nil {
                    kinds[ancestor] = .modified
                }
                ancestor = parentPath(of: ancestor)
            }
        }
        return sorted(kinds)
    }

    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// Path order with a directory before its contents (`/a`, `/a/b`, `/a-b`).
    private static func sorted(_ kinds: [String: RootfsDiff.Kind]) -> [RootfsDiff.Change] {
        kinds.map { RootfsDiff.Change(path: $0.key, kind: $0.value) }
            .sorted { $0.path.split(separator: "/").lexicographicallyPrecedes($1.path.split(separator: "/")) }
    }
}
