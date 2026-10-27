import ContainerAPIClient
import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("Container volume filter and mount points")
struct ContainerVolumeFilterTests {

    private func snapshot(id: String, mounts: [Filesystem], labels: [String: String] = [:]) throws -> ContainerSnapshot {
        let base = try makeContainerSnapshot(nativeId: id, networks: [], labels: labels)
        var config = base.configuration
        config.mounts = mounts
        return ContainerSnapshot(configuration: config, status: .running, networks: [])
    }

    private func fixtures() throws -> [ContainerSnapshot] {
        [
            try snapshot(
                id: "po-named",
                mounts: [.volume(name: "po-data", format: "ext4", source: "/vols/po-data/volume.img", destination: "/data", options: [])]),
            try snapshot(
                id: "po-bindvol",
                mounts: [.virtiofs(source: "/host/shared", destination: "/srv", options: [])],
                labels: [LocalBindVolume.containerLabel: LocalBindVolume.label(volumeNames: ["/srv": "po-bind"])!]),
            try snapshot(
                id: "po-bind",
                mounts: [.virtiofs(source: "/host/plain", destination: "/mnt", options: [])]),
            try snapshot(id: "po-none", mounts: []),
        ]
    }

    @Test(
        "volume filter matches a volume name, a mount destination, or a bind source",
        arguments: [
            ("po-data", ["po-named"]),
            ("/data", ["po-named"]),
            ("po-bind", ["po-bindvol"]),
            ("/srv", ["po-bindvol"]),
            ("/host/plain", ["po-bind"]),
            ("/mnt", ["po-bind"]),
            ("missing", []),
        ])
    func volumeFilter(value: String, expected: [String]) throws {
        let kept = ClientContainerService.applyFilters(try fixtures(), filters: ["volume": [value]])
        #expect(kept.map(\.id) == expected)
    }

    @Test("several volume values are OR-ed, as in moby")
    func volumeFilterOr() throws {
        let kept = ClientContainerService.applyFilters(try fixtures(), filters: ["volume": ["po-data", "/mnt"]])
        #expect(kept.map(\.id) == ["po-named", "po-bind"])
    }

    @Test("named and bind-backed volume mounts report the local driver; binds report none")
    func mountDrivers() throws {
        let all = try fixtures()
        let named = ContainerMountPoint.dockerMounts(for: all[0].configuration)
        #expect(named.map(\.driver) == ["local"])
        #expect(named.map(\.type) == ["volume"])
        let bindVolume = ContainerMountPoint.dockerMounts(for: all[1].configuration)
        #expect(bindVolume.map(\.driver) == ["local"])
        #expect(bindVolume.map(\.name) == ["po-bind"])
        let bind = ContainerMountPoint.dockerMounts(for: all[2].configuration)
        #expect(bind.map(\.type) == ["bind"])
        #expect(bind.map(\.driver) == [nil])
    }
}
