import ContainerResource
import Logging

/// Emits moby's per-network `connect` / `disconnect` events for a container's network
/// attachments. moby logs `connect` while initializing networking on start
/// (daemon.connectToNetwork) and `disconnect` while releasing it during exit cleanup
/// (daemon.releaseNetwork), both via `LogNetworkEventWithAttributes`: Actor.ID is the
/// network ID, attributes are `container` (full container id) plus the network's
/// `name` and `type` (driver).
enum NetworkAttachEvents {
    static func broadcastConnects(
        for snapshot: ContainerSnapshot,
        containerId: String,
        broadcaster: EventBroadcaster,
        networkClient: ClientNetworkProtocol = ClientNetworkService(),
        logger: Logger
    ) async {
        await broadcast("connect", for: snapshot, containerId: containerId, broadcaster: broadcaster, networkClient: networkClient, logger: logger)
    }

    static func broadcastDisconnects(
        for snapshot: ContainerSnapshot,
        containerId: String,
        broadcaster: EventBroadcaster,
        networkClient: ClientNetworkProtocol = ClientNetworkService(),
        logger: Logger
    ) async {
        await broadcast("disconnect", for: snapshot, containerId: containerId, broadcaster: broadcaster, networkClient: networkClient, logger: logger)
    }

    /// Configured network names, de-duplicated, in attachment order.
    static func networkNames(in snapshot: ContainerSnapshot) -> [String] {
        var seen = Set<String>()
        return snapshot.configuration.networks.map(\.network).filter { seen.insert($0).inserted }
    }

    private static func broadcast(
        _ action: String,
        for snapshot: ContainerSnapshot,
        containerId: String,
        broadcaster: EventBroadcaster,
        networkClient: ClientNetworkProtocol,
        logger: Logger
    ) async {
        for network in networkNames(in: snapshot) {
            // Network Id and Name are both the Apple network id; the lookup supplies the driver.
            let summary = try? await networkClient.getNetwork(id: network, logger: logger)
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "network", action: action, actorID: summary?.Id ?? network,
                    attributes: [
                        "container": containerId,
                        "name": summary?.Name ?? network,
                        "type": summary?.Driver ?? "nat",
                    ]))
        }
    }
}
