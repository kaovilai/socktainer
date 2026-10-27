import ContainerAPIClient
import ContainerPersistence
import Vapor

/// The image-store operations `podman untag` needs; a seam so tests need no image store.
protocol ImageUntagStore: Sendable {
    /// The digest of the image `name` refers to (by reference or ID); throws when there is none.
    func digest(of name: String, config: ContainerSystemConfig) async throws -> String
    /// Every stored reference to `digest`.
    func references(to digest: String) async throws -> [String]
    /// Adds `new` as a reference to the image `existing` refers to.
    func tag(existing: String, new: String, config: ContainerSystemConfig) async throws
    func delete(reference: String) async throws
}

struct LiveImageUntagStore: ImageUntagStore {
    func digest(of name: String, config: ContainerSystemConfig) async throws -> String {
        try await ImageIDResolver.get(name, containerSystemConfig: config).digest
    }

    func references(to digest: String) async throws -> [String] {
        try await ClientImage.list().filter { $0.digest == digest }.map(\.reference)
    }

    func tag(existing: String, new: String, config: ContainerSystemConfig) async throws {
        _ = try await ImageIDResolver.get(existing, containerSystemConfig: config).tag(new: new)
    }

    func delete(reference: String) async throws {
        try await ClientImage.delete(reference: reference, garbageCollect: false)
    }
}

/// `podman untag`: POST `/libpod/images/{name}/untag` removes one name (`repo` + `tag`) or, with
/// neither, every name of the image. Unlike `rmi` it never removes the image: an image left with
/// no name becomes dangling. The image store cannot hold an image without a reference, so a
/// dangling one keeps the `untagged@<digest>` reference `docker build` gives a tag-less image,
/// which listings show as `<none>`.
struct LibpodImageUntagRoute: RouteCollection {
    let systemConfig: ContainerSystemConfig
    let store: ImageUntagStore

    init(systemConfig: ContainerSystemConfig, store: ImageUntagStore = LiveImageUntagStore()) {
        self.systemConfig = systemConfig
        self.store = store
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/{name:.*}/untag") { [systemConfig, store] req in
            guard let name = req.parameters.get("name") else {
                throw Abort(.badRequest, reason: "Missing image name parameter")
            }
            let query = try req.query.decode(RESTImageTagQuery.self)
            let removed = try await Self.untag(name: name, repo: query.repo, tag: query.tag, config: systemConfig, store: store)
            if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
                for (digest, reference) in removed {
                    await broadcaster.broadcast(DockerEvent.make(type: "image", action: "untag", actorID: digest, attributes: ["name": reference]))
                }
            }
            return Response(status: .created)
        }
    }

    static func isDangling(_ reference: String) -> Bool {
        reference.hasPrefix("untagged@") || reference.contains("<none>")
    }

    /// Removes the requested names and answers the (digest, reference) pairs it removed.
    static func untag(
        name: String, repo: String?, tag: String?, config: ContainerSystemConfig, store: ImageUntagStore
    ) async throws -> [(String, String)] {
        let digest: String
        do {
            digest = try await store.digest(of: name, config: config)
        } catch {
            throw Abort(.notFound, reason: "No such image: \(name)")
        }
        let references = try await store.references(to: digest)
        let names = references.filter { !isDangling($0) }

        let targets: [String]
        if let repo, !repo.isEmpty {
            let reference = try ClientImage.normalizeReference("\(repo):\(tag?.isEmpty == false ? tag! : "latest")", containerSystemConfig: config)
            guard names.contains(reference) else {
                throw Abort(.notFound, reason: "\(reference): tag not known")
            }
            targets = [reference]
        } else {
            targets = names
        }
        guard !targets.isEmpty else { return [] }

        // Removing the image's last reference would remove the image, so it is kept under the
        // dangling reference first.
        if references.allSatisfy({ targets.contains($0) }) {
            try await store.tag(existing: targets[0], new: "untagged@\(digest)", config: config)
        }
        for target in targets {
            try await store.delete(reference: target)
        }
        return targets.map { (digest, $0) }
    }
}
