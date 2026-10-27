import ContainerResource
import Foundation

extension ContainerMountPoint {
    /// The Docker `Mounts` entries for a container configuration, shared by `docker ps` and
    /// `docker inspect` so both report the same type, name and driver for every mount.
    static func dockerMounts(for configuration: ContainerConfiguration) -> [ContainerMountPoint] {
        let bindVolumeNames = LocalBindVolume.volumeNames(labels: configuration.labels)
        return configuration.mounts.map { mount in
            let mountType: String
            let mountName: String?
            let driver: String?

            switch mount.type {
            case .block(_, _, _):
                mountType = "bind"
                mountName = nil
                driver = nil
            case .volume(let name, _, _, _):
                mountType = "volume"
                mountName = name
                driver = "local"
            case .virtiofs:
                // A bind-backed named volume is shared over virtiofs but is still a volume.
                let volumeName = bindVolumeNames[mount.destination]
                mountType = volumeName == nil ? "bind" : "volume"
                mountName = volumeName
                driver = volumeName == nil ? nil : "local"
            case .tmpfs:
                mountType = "tmpfs"
                mountName = nil
                driver = nil
            }

            let isReadOnly = mount.options.readonly
            return ContainerMountPoint(
                type: mountType,
                name: mountName,
                source: mount.source,
                destination: mount.destination,
                driver: driver,
                mode: isReadOnly ? "ro" : "rw",
                rw: !isReadOnly,
                propagation: ""
            )
        }
    }
}
