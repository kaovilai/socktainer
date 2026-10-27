import Vapor

/// `podman diff <container>`: podman's endpoint answers with the same `{Path, Kind}` list.
///
/// podman's handler serves images too: `podman image diff` (and `podman diff` given an
/// image) calls this endpoint with `diffType=image`, and the default `all` falls back to an
/// image when no container has the name. Images are diffed by `LibpodImageChangesRoute`.
struct LibpodContainerChangesRoute: RouteCollection {
    typealias ImageChanges = @Sendable (_ name: String, _ parent: String?, _ req: Request) async throws -> [RESTContainerChange]

    let containerClient: ClientContainerProtocol
    let changesClient: ClientContainerChangesProtocol
    var imageChanges: ImageChanges = { name, _, _ in
        throw Abort(.notFound, reason: "\(name): image not known")
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/libpod/containers/{id}/changes",
            use: LibpodContainerChangesRoute.handler(containerClient: containerClient, changesClient: changesClient, imageChanges: imageChanges))
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        changesClient: ClientContainerChangesProtocol,
        imageChanges: @escaping ImageChanges
    ) -> @Sendable (Request) async throws -> [RESTContainerChange] {
        let containerChanges = ContainerChangesRoute.handler(containerClient: containerClient, changesClient: changesClient)
        return { req in
            guard let name = req.parameters.get("id") else {
                throw Abort(.badRequest, reason: "Missing container ID")
            }
            // podman's client sends `difftype`; its schema decoder matches names case-insensitively.
            let diffType = queryValue(["diffType", "difftype"], in: req) ?? "all"
            let parent = queryValue(["parent"], in: req)
            switch diffType {
            case "container":
                return try await containerChanges(req)
            case "image":
                return try await imageChanges(name, parent, req)
            case "", "all":
                let isContainer: Bool
                do {
                    isContainer = try await containerClient.getContainer(id: name) != nil
                } catch {
                    // An ambiguous reference names containers; let the container path report it.
                    isContainer = true
                }
                if isContainer {
                    return try await containerChanges(req)
                }
                do {
                    return try await imageChanges(name, parent, req)
                } catch let abort as Abort where abort.status == .notFound {
                    throw Abort(.notFound, reason: "\(name) not found: no such container or image")
                }
            default:
                throw Abort(.badRequest, reason: "invalid diff type \"\(diffType)\": must be one of all, container, image")
            }
        }
    }

    private static func queryValue(_ names: [String], in req: Request) -> String? {
        for name in names {
            if let value = allQueryValues(named: name, from: req.url.query).first {
                return value
            }
        }
        return nil
    }
}
