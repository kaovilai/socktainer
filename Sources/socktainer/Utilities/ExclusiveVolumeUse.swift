import ContainerResource
import Vapor

/// Apple Container backs a default named volume with an ext4 disk image. A second running
/// container that attaches the same image mounts its own copy of the filesystem: both start, but
/// each sees only its own writes, and two kernels writing one ext4 image corrupt it. Docker shares
/// a named volume between running containers, so the safe answer short of sharing is to refuse
/// the second start with a conflict that names the volume and the container holding it.
///
/// Volumes created with local-driver bind options are mounted over virtiofs from their host
/// directory (`LocalBindVolume`), not as a disk image, and are shared freely.
enum ExclusiveVolumeUse {
    /// The disk-image named volumes the container mounts.
    static func diskImageVolumes(of container: ContainerSnapshot) -> [String] {
        container.configuration.mounts.compactMap {
            guard case .volume(let name, _, _, _) = $0.type else { return nil }
            return name
        }
    }

    /// The first disk-image volume `container` mounts that another running container already has
    /// mounted, with that container.
    static func conflict(for container: ContainerSnapshot, among containers: [ContainerSnapshot]) -> ExclusiveVolumeInUseError? {
        let wanted = diskImageVolumes(of: container)
        guard !wanted.isEmpty else { return nil }
        for other in containers where other.id != container.id && other.status == .running {
            let held = Set(diskImageVolumes(of: other))
            if let volume = wanted.first(where: held.contains) {
                return ExclusiveVolumeInUseError(volume: volume, holder: other.id)
            }
        }
        return nil
    }
}

struct ExclusiveVolumeInUseError: AbortError, Equatable {
    let volume: String
    let holder: String

    var status: HTTPResponseStatus { .conflict }

    var reason: String {
        "volume \"\(volume)\" is in use by running container \(holder); ext4-backed volumes can't be shared"
            + " — create it with --opt type=none --opt o=bind --opt device=<dir> to share"
    }
}
