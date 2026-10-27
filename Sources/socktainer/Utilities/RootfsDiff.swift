import ContainerizationEXT4
import Foundation
import SystemPackage

/// `docker diff` / `podman diff`: what a container changed relative to its image.
///
/// Apple Container gives each container a private `rootfs.ext4` cloned from the image's
/// unpacked snapshot at first start, so the two filesystems start out identical
/// (inode metadata included) and every write lands only in the clone. Walking both and
/// comparing entries recovers what moby gets from the container's writable layer.
///
/// Comparison follows moby's `archive.ChangesDirs`: a path present only in the container
/// is added (with everything under it), one present only in the image is deleted (its
/// children are not listed), and one present in both is modified when its type,
/// permissions, owner, or — for anything but a directory — size or modification time
/// differ. A directory whose contents changed is reported modified even when its own
/// metadata did not. Output is in path order, a directory before its contents.
enum RootfsDiffError: Error, Equatable {
    case nestingTooDeep(path: String)
}

enum RootfsDiff {
    enum Kind: Int, Codable, Sendable {
        case modified = 0
        case added = 1
        case deleted = 2
    }

    struct Change: Equatable, Sendable {
        let path: String
        let kind: Kind
    }

    /// Files the runtime writes into every container's rootfs at start. moby keeps these
    /// in a per-container init layer the diff is taken against, so `docker diff` never
    /// lists them; they are skipped here for the same result.
    static let runtimeManagedPaths: Set<String> = ["/etc/hosts", "/etc/hostname", "/etc/resolv.conf"]

    /// Bounds the walk against a pathological (or crafted) directory depth.
    static let maxDepth = 4096

    static func changes(base: EXT4.EXT4Reader, container: EXT4.EXT4Reader) throws -> [Change] {
        var changes: [Change] = []
        try compareDirectory("/", base: base, container: container, depth: 0, into: &changes)
        return changes
    }

    private static func compareDirectory(
        _ path: String, base: EXT4.EXT4Reader, container: EXT4.EXT4Reader, depth: Int, into changes: inout [Change]
    ) throws {
        guard depth < maxDepth else {
            throw RootfsDiffError.nestingTooDeep(path: path)
        }
        let baseNames = Set(try base.listDirectory(FilePath(path)))
        let containerNames = Set(try container.listDirectory(FilePath(path)))

        for name in baseNames.union(containerNames).sorted() {
            let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
            guard !runtimeManagedPaths.contains(child) else { continue }
            guard containerNames.contains(name) else {
                changes.append(Change(path: child, kind: .deleted))
                continue
            }
            let current = try container.stat(FilePath(child), followSymlinks: false).inode
            guard baseNames.contains(name) else {
                try appendAdded(child, inode: current, container: container, depth: depth + 1, into: &changes)
                continue
            }
            let original = try base.stat(FilePath(child), followSymlinks: false).inode

            if isDirectory(current) && isDirectory(original) {
                var nested: [Change] = []
                try compareDirectory(child, base: base, container: container, depth: depth + 1, into: &nested)
                if !nested.isEmpty || metadataDiffers(original, current) {
                    changes.append(Change(path: child, kind: .modified))
                }
                changes.append(contentsOf: nested)
            } else if metadataDiffers(original, current) {
                changes.append(Change(path: child, kind: .modified))
                // A non-directory replaced by a directory: its contents are new.
                if isDirectory(current) {
                    try appendContentsAdded(child, container: container, depth: depth + 1, into: &changes)
                }
            }
        }
    }

    private static func appendAdded(
        _ path: String, inode: EXT4.Inode, container: EXT4.EXT4Reader, depth: Int, into changes: inout [Change]
    ) throws {
        changes.append(Change(path: path, kind: .added))
        if isDirectory(inode) {
            try appendContentsAdded(path, container: container, depth: depth, into: &changes)
        }
    }

    private static func appendContentsAdded(_ path: String, container: EXT4.EXT4Reader, depth: Int, into changes: inout [Change]) throws {
        guard depth < maxDepth else {
            throw RootfsDiffError.nestingTooDeep(path: path)
        }
        for name in try container.listDirectory(FilePath(path)) {
            let child = "\(path)/\(name)"
            let inode = try container.stat(FilePath(child), followSymlinks: false).inode
            try appendAdded(child, inode: inode, container: container, depth: depth + 1, into: &changes)
        }
    }

    private static let typeMask: UInt16 = 0xF000
    private static let directoryType: UInt16 = 0x4000

    static func isDirectory(_ inode: EXT4.Inode) -> Bool {
        inode.mode & typeMask == directoryType
    }

    static func metadataDiffers(_ old: EXT4.Inode, _ new: EXT4.Inode) -> Bool {
        if old.mode != new.mode || uid(old) != uid(new) || gid(old) != gid(new) {
            return true
        }
        // moby: "Don't look at size for dirs, its not a good measure of change".
        if isDirectory(new) {
            return false
        }
        return size(old) != size(new) || old.mtime != new.mtime || old.mtimeExtra != new.mtimeExtra
    }

    private static func uid(_ inode: EXT4.Inode) -> UInt32 { UInt32(inode.uid) | UInt32(inode.uidHigh) << 16 }
    private static func gid(_ inode: EXT4.Inode) -> UInt32 { UInt32(inode.gid) | UInt32(inode.gidHigh) << 16 }
    private static func size(_ inode: EXT4.Inode) -> UInt64 { UInt64(inode.sizeLow) | UInt64(inode.sizeHigh) << 32 }
}
