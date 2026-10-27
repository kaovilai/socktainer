import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation
import Logging
import Testing

@testable import socktainer

/// moby logs a `network connect` per attached network when a container starts and a
/// `network disconnect` when its networking is released on exit
/// (`LogNetworkEventWithAttributes`: Actor.ID = network id; container/name/type attributes).
@Suite("Network connect/disconnect events on container start/exit")
struct NetworkAttachEventTests {
    private func snapshot(networks: [String]) throws -> ContainerSnapshot {
        var snap = try makeContainerSnapshot(nativeId: "net-ev-ctr", ip: "192.168.65.2", network: "default", labels: [:])
        snap.configuration.networks = networks.map {
            AttachmentConfiguration(network: $0, options: AttachmentOptions(hostname: "net-ev-ctr"))
        }
        return snap
    }

    private func capture(
        _ action: String, networks: [String], client: ClientNetworkProtocol
    ) async throws -> [DockerEvent] {
        let snap = try snapshot(networks: networks)
        let broadcaster = EventBroadcaster()
        let logger = Logger(label: "test")
        if action == "connect" {
            await NetworkAttachEvents.broadcastConnects(for: snap, containerId: "c0ffee", broadcaster: broadcaster, networkClient: client, logger: logger)
        } else {
            await NetworkAttachEvents.broadcastDisconnects(for: snap, containerId: "c0ffee", broadcaster: broadcaster, networkClient: client, logger: logger)
        }
        return await broadcaster.recentEvents()
    }

    @Test("connect: one event per configured network with moby's attributes")
    func connectPerNetwork() async throws {
        let events = try await capture("connect", networks: ["frontend", "backend", "frontend"], client: DriverStubNetworkClient())
        #expect(events.count == 2, "duplicate attachments emit once")
        #expect(events.map(\.Type) == ["network", "network"])
        #expect(events.map(\.Action) == ["connect", "connect"])
        #expect(events.map(\.Actor.ID) == ["frontend", "backend"])
        #expect(events[0].Actor.Attributes == ["container": "c0ffee", "name": "frontend", "type": "hostOnly"])
    }

    @Test("disconnect falls back to the attachment name and nat when the network is gone")
    func disconnectFallback() async throws {
        let events = try await capture("disconnect", networks: ["gone"], client: MissingNetworkClient())
        #expect(events.map(\.Action) == ["disconnect"])
        #expect(events[0].Actor.ID == "gone")
        #expect(events[0].Actor.Attributes == ["container": "c0ffee", "name": "gone", "type": "nat"])
    }

    @Test("libpod translation keeps connect/disconnect in podman's container-centric shape")
    func libpodKeeps() async throws {
        let events = try await capture("connect", networks: ["n"], client: DriverStubNetworkClient())
        let translated = try #require(LibpodEventTranslation.translate(events[0]))
        #expect(translated.Action == "connect")
        #expect(translated.Actor.ID == "c0ffee")
        #expect(translated.Actor.Attributes == ["network": "n"])
    }
}

private struct DriverStubNetworkClient: ClientNetworkProtocol {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? {
        RESTNetworkSummary(
            Name: id, Id: id, Created: "", Scope: "local", Driver: "hostOnly",
            EnableIPv4: true, EnableIPv6: false, Internal: false, Attachable: false, Ingress: false,
            IPAM: NetworkIPAM(Driver: "", Config: []), Options: [:], Containers: nil,
            ConfigFrom: nil, Labels: [:], Subnet: nil, Gateway: nil)
    }
    func create(name: String, labels: [String: String], ipv4Subnet: String?, mode: NetworkMode, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
    func delete(id: String, logger: Logger) async throws {}
}

private struct MissingNetworkClient: ClientNetworkProtocol {
    func list(filters: String?, logger: Logger) async throws -> [RESTNetworkSummary] { [] }
    func getNetwork(id: String, logger: Logger) async throws -> RESTNetworkSummary? { nil }
    func create(name: String, labels: [String: String], ipv4Subnet: String?, mode: NetworkMode, logger: Logger) async throws -> RESTNetworkCreate {
        RESTNetworkCreate(Id: name, Warning: "")
    }
    func delete(id: String, logger: Logger) async throws {}
}
