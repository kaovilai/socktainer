import ContainerResource
import Foundation

/// A container that has run keeps its private root filesystem (and its log) in its Apple
/// Container bundle, which a delete removes. Apple Container has no rename, so renaming one
/// rebuilds it under the new name; this carries those files across the rebuild: they are moved
/// out of the old bundle before it is deleted and into the new one once it exists, and the new
/// container is created with its root filesystem pointing at them (Apple Container builds the
/// bundle on first boot and only clones the image when no root filesystem is given).
struct RenameCarryOver {
    static let rootfsFilename = "rootfs.ext4"
    static let carriedFilenames = [rootfsFilename, "stdio.log"]

    /// Where the carried files wait between the delete and the create.
    let stagingDirectory: URL
    /// The old container's root filesystem description, `source` aside.
    let rootfs: Filesystem

    /// Moves the root filesystem and log out of `bundle`; nil when the container never ran
    /// (it has no root filesystem of its own yet, and the image is cloned on its first boot).
    static func stage(from bundle: URL, into stagingDirectory: URL) throws -> RenameCarryOver? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundle.appendingPathComponent(rootfsFilename).path) else { return nil }
        let rootfs = try rootfsDescription(of: bundle)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        for name in carriedFilenames where fileManager.fileExists(atPath: bundle.appendingPathComponent(name).path) {
            try fileManager.moveItem(at: bundle.appendingPathComponent(name), to: stagingDirectory.appendingPathComponent(name))
        }
        return RenameCarryOver(stagingDirectory: stagingDirectory, rootfs: rootfs)
    }

    /// The runtime records the root filesystem when it builds the bundle on first boot; a container
    /// already rebuilt by a rename that has not booted since only has it in its runtime configuration.
    static func rootfsDescription(of bundle: URL) throws -> Filesystem {
        if let booted = try? ContainerResource.Bundle(path: bundle).containerRootfs {
            return booted
        }
        let data = try Data(contentsOf: bundle.appendingPathComponent("runtime-configuration.json"))
        guard let override = try JSONDecoder().decode(RuntimeOptions.self, from: data).options?.rootFsOverride else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: bundle.path])
        }
        return override
    }

    /// The part of Apple Container's `runtime-configuration.json` this reads.
    private struct RuntimeOptions: Decodable {
        let options: ContainerCreateOptions?
    }

    /// The create options for the container rebuilt at `bundle`, its root filesystem being the carried one.
    func createOptions(autoRemove: Bool, bundle: URL) -> ContainerCreateOptions {
        var rootfs = self.rootfs
        rootfs.source = bundle.appendingPathComponent(Self.rootfsFilename).path
        return ContainerCreateOptions(autoRemove: autoRemove, rootFsOverride: rootfs)
    }

    /// Moves the carried files into `bundle` (which the create made) and drops the staging directory.
    func land(in bundle: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in Self.carriedFilenames where fileManager.fileExists(atPath: stagingDirectory.appendingPathComponent(name).path) {
            let destination = bundle.appendingPathComponent(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: stagingDirectory.appendingPathComponent(name), to: destination)
        }
        try? fileManager.removeItem(at: stagingDirectory)
    }
}
