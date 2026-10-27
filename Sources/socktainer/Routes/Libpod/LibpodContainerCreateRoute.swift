import ContainerPersistence
import Foundation
import Vapor

struct LibpodContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol
    let systemConfig: ContainerSystemConfig
    var podStore: PodStore = .shared
    var networkClient: ClientNetworkProtocol = ClientNetworkService()

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/containers/create",
            use: LibpodContainerCreateRoute.handler(
                client: client, systemConfig: systemConfig,
                ensurePodNetwork: LibpodPodRuntime.live(client: client, networkClient: networkClient).ensureNetwork, podStore: podStore))
    }

    /// Podman posts its whole `SpecGenerator`; it is translated into a Docker create body and
    /// handed to the Docker-compat handler, which answers with the same `{Id, Warnings}` shape.
    static func handler(
        client: ClientContainerProtocol, systemConfig: ContainerSystemConfig,
        ensurePodNetwork: @escaping @Sendable (Request, PodRecord) async throws -> Void = { _, _ in }, podStore: PodStore = .shared
    ) -> @Sendable (Request) async throws -> Response {
        LibpodAdapter.preparing(ContainerCreateRoute.handler(client: client, systemConfig: systemConfig)) { req in
            let spec = try await LibpodAdapter.jsonObjectBody(of: req)
            guard let image = spec["image"] as? String, !image.isEmpty else {
                throw Abort(.badRequest, reason: "Missing image")
            }
            if let name = spec["name"] as? String, !name.isEmpty {
                LibpodAdapter.setQuery(req, "name", to: name)
            }
            // `--platform` travels in the spec; Docker-compat create takes it as a query parameter.
            if let platform = LibpodSchema.platform(fromSpec: spec) {
                LibpodAdapter.setQuery(req, "platform", to: platform)
            }
            var body = LibpodSchema.dockerContainerCreateBody(fromSpec: spec)
            // `--pod`: podman's `new:` form is resolved by the client, which creates the pod first.
            if let podName = spec["pod"] as? String, !podName.isEmpty {
                guard let pod = await podStore.resolve(podName) else { throw LibpodPodRoute.notFound(podName) }
                if LibpodPodSchema.joinPod(pod, body: &body) != nil {
                    try await ensurePodNetwork(req, pod)
                }
            }
            return try LibpodAdapter.replacingBody(of: req, with: body)
        }
    }
}
