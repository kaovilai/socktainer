import Vapor

struct LibpodContainerListRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        let client = self.client
        let handler = LibpodAdapter.reshaping(ContainerListRoute.handler(client: client)) { body, _ in
            // Docker's summary has no start time, which podman needs to render "Up 2 hours".
            var startedAt: [String: Double] = [:]
            for container in try await client.list(showAll: true, filters: [:]) {
                // The snapshot's start date can be absent for a container that has been running
                // a long time; fall back to its creation date rather than reporting the epoch.
                let started = container.lastStartedDate ?? AppleContainerTimestampResolver.containerCreationDate(container)
                if let started { startedAt[DockerContainerID.hexId(for: container)] = started.timeIntervalSince1970 }
            }
            let podNames = Dictionary(await PodStore.shared.all().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            return LibpodSchema.containerList(body, startedAt: startedAt, podNames: podNames)
        }
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/containers/json", use: handler)
    }
}
