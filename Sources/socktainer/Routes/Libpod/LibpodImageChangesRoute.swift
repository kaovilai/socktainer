import ContainerAPIClient
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Vapor

/// Query of `GET /libpod/images/{name}/changes` (podman's `Changes` handler).
struct RESTLibpodImageChangesQuery: Vapor.Content {
    /// An image to compare against instead of the image's own lower layers.
    let parent: String?
    /// `all`, `container` or `image`.
    let diffType: String?
}

/// `podman image diff`: the filesystem changes an image's top layer makes over the layers
/// below it (`ImageLayerChanges.topLayerChanges`), or — with `parent` — how the image's
/// whole filesystem differs from the parent image's (`ImageLayerChanges.treeChanges`).
/// Read straight from the layer blobs in the content store; Docker has no counterpart.
struct LibpodImageChangesRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .GET, pattern: "/libpod/images/{name:.*}/changes", use: LibpodImageChangesRoute.handler(systemConfig: systemConfig))
    }

    static func handler(systemConfig: ContainerSystemConfig) -> @Sendable (Request) async throws -> [RESTContainerChange] {
        { req in
            guard let name = req.parameters.get("name"), !name.isEmpty else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            guard let appSupport = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }
            let query = try req.query.decode(RESTLibpodImageChangesQuery.self)
            switch query.diffType ?? "all" {
            case "", "all", "image":
                break
            case "container":
                // podman looks the name up among containers only, which images are not.
                throw Abort(.notFound, reason: "no container with name or ID \"\(name)\" found: no such container")
            default:
                throw Abort(.badRequest, reason: "invalid diff type \"\(query.diffType ?? "")\": must be one of all, container, image")
            }

            return try await changes(of: name, parent: query.parent, systemConfig: systemConfig, appSupport: appSupport)
        }
    }

    /// `name`'s changes over its own lower layers, or over the image `parent` when given.
    static func changes(of name: String, parent: String?, systemConfig: ContainerSystemConfig, appSupport: URL) async throws
        -> [RESTContainerChange]
    {
        let blobs = appSupport.appendingPathComponent("content/blobs/sha256")
        let layers = try await layerBlobs(of: name, systemConfig: systemConfig, blobs: blobs)
        let parentLayers: [URL]?
        if let parent, !parent.isEmpty {
            parentLayers = try await layerBlobs(of: parent, systemConfig: systemConfig, blobs: blobs)
        } else {
            parentLayers = nil
        }

        let changes: [RootfsDiff.Change]
        do {
            changes = try await Task.detached(priority: .utility) {
                let read = try layers.map { try ImageLayerChanges.readLayer(at: $0) }
                if let parentLayers {
                    let parentRead = try parentLayers.map { try ImageLayerChanges.readLayer(at: $0) }
                    return ImageLayerChanges.treeChanges(from: ImageLayerChanges.tree(of: parentRead), to: ImageLayerChanges.tree(of: read))
                }
                guard let top = read.last else { return [] }
                return ImageLayerChanges.topLayerChanges(top, lower: ImageLayerChanges.tree(of: Array(read.dropLast())))
            }.value
        } catch {
            throw Abort(.internalServerError, reason: "failed to read the layers of \(name): \(error)")
        }
        return changes.map { RESTContainerChange(Path: $0.path, Kind: $0.kind.rawValue) }
    }

    /// `changes(of:parent:)` bound to this daemon's image store, for the container route.
    static func lookup(systemConfig: ContainerSystemConfig) -> LibpodContainerChangesRoute.ImageChanges {
        { name, parent, req in
            guard let appSupport = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
                throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
            }
            return try await changes(of: name, parent: parent, systemConfig: systemConfig, appSupport: appSupport)
        }
    }

    /// The layer blobs of `name`'s manifest for its platform, bottom first.
    static func layerBlobs(of name: String, systemConfig: ContainerSystemConfig, blobs: URL) async throws -> [URL] {
        let resolved: ImageIDResolver.Resolved
        do {
            resolved = try await ImageIDResolver.resolve(name, containerSystemConfig: systemConfig)
        } catch {
            throw Abort(.notFound, reason: "\(name): image not known")
        }
        let manifest: Manifest
        do {
            manifest = try await resolved.image.manifest(for: requestedOrDefaultPlatform(resolved.platform))
        } catch {
            throw Abort(.notFound, reason: "\(name): no manifest for this platform: \(error)")
        }
        return try manifest.layers.map { layer in
            let hex = layer.digest.hasPrefix("sha256:") ? String(layer.digest.dropFirst("sha256:".count)) : layer.digest
            let url = blobs.appendingPathComponent(hex)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Abort(.notFound, reason: "\(name): layer \(layer.digest) is not in the local store")
            }
            return url
        }
    }
}
