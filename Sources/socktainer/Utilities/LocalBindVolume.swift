import ContainerResource
import Foundation

/// A `local`-driver volume created with bind options
/// (`docker volume create --opt type=none --opt o=bind --opt device=/host/dir`), which moby and
/// podman back with the host directory `device` instead of storage of their own.
///
/// Apple Container stores every volume as an ext4 disk image, and a disk image can be attached
/// to only one running VM at a time ("The storage device attachment is invalid"). A bind-backed
/// volume is mounted with virtiofs instead, the same way a `-v /host:/ctr` bind mount is, so any
/// number of running containers can share it. Apple still allocates a (sparse, unused) image for
/// the volume; socktainer just never mounts it.
struct LocalBindVolume: Equatable {
    /// Container label mapping each bind-backed volume's mount destination to the volume name.
    /// The mount itself is a plain virtiofs share, so without it inspect would report a bind.
    static let containerLabel = "socktainer.bind-volumes"

    /// The volume names recorded in `containerLabel`, keyed by mount destination.
    static func volumeNames(labels: [String: String]) -> [String: String] {
        guard let raw = labels[containerLabel], let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func label(volumeNames: [String: String]) -> String? {
        guard !volumeNames.isEmpty, let data = try? JSONEncoder().encode(volumeNames) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Docker IDs of the containers that mount the bind-backed volume `name`, as moby lists them
    /// when refusing to remove a volume in use.
    static func containers(using name: String, in containers: [ContainerSnapshot]) -> [String] {
        containers.filter { volumeNames(labels: $0.configuration.labels).values.contains(name) }
            .map { DockerContainerID.hexId(for: $0) }
    }

    /// The host directory backing the volume.
    let device: String
    /// Whether `o` asked for a read-only mount (`o=bind,ro`).
    let readOnly: Bool

    /// The bind configuration in a volume's driver options, or nil when the options do not ask
    /// for a bind mount.
    init?(options: [String: String]) {
        let mountOptions = Self.mountOptions(options)
        guard mountOptions.contains("bind") || mountOptions.contains("rbind"),
            let device = options["device"], !device.isEmpty
        else { return nil }
        self.device = device
        self.readOnly = mountOptions.contains("ro")
    }

    /// Rejects bind options moby's local driver would refuse, before the volume is created.
    static func validate(options: [String: String]) throws {
        let mountOptions = Self.mountOptions(options)
        guard mountOptions.contains("bind") || mountOptions.contains("rbind") else { return }
        guard let device = options["device"], !device.isEmpty else {
            throw LocalBindVolumeError.missingDevice
        }
        guard device.hasPrefix("/") else { throw LocalBindVolumeError.relativeDevice(device) }
        if let type = options["type"], !type.isEmpty, type != "none" {
            throw LocalBindVolumeError.unsupportedType(type)
        }
    }

    /// Fails when the backing directory is missing, as mounting such a volume fails on moby.
    func checkDeviceExists(volumeName: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: device, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalBindVolumeError.deviceMissing(volume: volumeName, device: device)
        }
    }

    /// Mount options for the virtiofs share, on top of the ones the container asked for.
    func mountOptions(adding requested: [String]) -> [String] {
        readOnly && !requested.contains("ro") ? requested + ["ro"] : requested
    }

    private static func mountOptions(_ options: [String: String]) -> [String] {
        (options["o"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

enum LocalBindVolumeError: Error, Equatable, CustomStringConvertible {
    case missingDevice
    case relativeDevice(String)
    case unsupportedType(String)
    case deviceMissing(volume: String, device: String)

    var description: String {
        switch self {
        case .missingDevice:
            return "missing required option: \"device\""
        case .relativeDevice(let device):
            return "invalid device \(device): a bind-mounted volume needs an absolute host path"
        case .unsupportedType(let type):
            return "unsupported volume mount type \(type) with o=bind: only type=none is supported"
        case .deviceMissing(let volume, let device):
            return "error while mounting volume '\(volume)': failed to mount local volume: mount \(device): no such file or directory"
        }
    }
}
