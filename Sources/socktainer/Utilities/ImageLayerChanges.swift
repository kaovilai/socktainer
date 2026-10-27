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
}
