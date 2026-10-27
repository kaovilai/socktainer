import ContainerAPIClient
import ContainerResource
import Foundation
import Vapor

/// Query of `POST /commit` (moby `postCommit`). `changes` repeats once per instruction.
struct RESTCommitQuery: Content {
    let container: String?
    let repo: String?
    let tag: String?
    let comment: String?
    let author: String?
    let pause: Bool?
}

/// `docker commit`: snapshots a container's filesystem into a new image.
///
/// Like moby, the new image is the base image's layers plus one layer of the container's
/// changes (`RootfsDiff` against the image snapshot the rootfs was cloned from). When the
/// changes cannot be separated from the image, the whole rootfs is committed as a single
/// squashed layer instead. The config is composed by `CommitConfigComposer`. A running container is not paused (no
/// pause primitive); its guest page cache is flushed before the rootfs is read, the same
/// volatile-snapshot guarantee `docker export` gives.
struct CommitRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol
    let imageClient: ClientImageCommitProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/commit",
            use: CommitRoute.handler(containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient))
    }

    struct CommitRequest {
        var container: String
        var repo: String?
        var tag: String?
        var comment: String?
        var author: String?
        var changes: [String]
        var config: Data?
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol,
        imageClient: ClientImageCommitProtocol
    ) -> @Sendable (Vapor.Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTCommitQuery.self)
            guard let container = query.container, !container.isEmpty else {
                throw Abort(.badRequest, reason: "Missing container query parameter")
            }
            let commit = CommitRequest(
                container: container,
                repo: query.repo,
                tag: query.tag,
                comment: query.comment,
                author: query.author,
                changes: allQueryValues(named: "changes", from: req.url.query),
                config: req.body.data.map { Data(buffer: $0) }
            )
            let id = try await perform(commit, req: req, containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient)
            return try await RESTCommitResponse(Id: id).encodeResponse(status: .created, for: req)
        }
    }

    /// Shared by the Docker and libpod routes; returns the new image's id.
    static func perform(
        _ commit: CommitRequest,
        req: Vapor.Request,
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol,
        imageClient: ClientImageCommitProtocol
    ) async throws -> String {
        guard let appSupport = req.application.storage[AppleContainerAppSupportUrlKey.self] else {
            throw Abort(.internalServerError, reason: "AppleContainerAppSupportUrl not configured")
        }

        let resolved: ContainerSnapshot?
        do {
            resolved = try await containerClient.getContainer(id: commit.container)
        } catch ClientContainerError.ambiguousId(let reference, let matches) {
            throw Abort(.badRequest, reason: "ambiguous container reference \(reference): matches \(matches.joined(separator: ", "))")
        }
        guard let container = resolved else {
            throw Abort(.notFound, reason: "No such container: \(commit.container)")
        }

        let overrides: [String: Any]?
        if let body = commit.config, !body.isEmpty, body != Data("null".utf8) {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw Abort(.badRequest, reason: "commit config must be a JSON object")
            }
            overrides = object
        } else {
            overrides = nil
        }

        let platform = container.configuration.platform
        let layered = await changeLayer(
            of: container, archiveClient: archiveClient, imageClient: imageClient, appSupport: appSupport, logger: req.logger)
        defer {
            if let layered { try? FileManager.default.removeItem(at: layered.layer.tarPath) }
        }

        // A base image deleted since the container was created leaves only what the
        // container itself records.
        let base: [String: Any]
        if let layered,
            let object = try? JSONSerialization.jsonObject(with: layered.base.config) as? [String: Any]
        {
            base = object["config"] as? [String: Any] ?? [:]
        } else if let raw = try? await imageClient.rawImageConfig(
            reference: container.configuration.image.reference, platform: platform, appleContainerAppSupportUrl: appSupport),
            let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        {
            base = object["config"] as? [String: Any] ?? [:]
        } else {
            req.logger.warning("Base image \(container.configuration.image.reference) unavailable; committing \(container.id) with its own config only")
            base = [:]
        }

        let process = container.configuration.initProcess
        let composed: [String: Any]
        do {
            composed = try CommitConfigComposer.compose(
                base: base,
                container: CommitConfigComposer.Container(
                    executable: process.executable,
                    arguments: process.arguments,
                    env: process.environment,
                    workingDir: process.workingDirectory,
                    user: commitUser(process.user),
                    labels: LabelNormalization.restore(container.configuration.labels)
                ),
                overrides: overrides,
                changes: commit.changes
            )
        } catch let error as DockerfileChangeError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
        let configJSON = try JSONSerialization.data(withJSONObject: composed)

        let tarPath: URL
        if let layered {
            tarPath = layered.layer.tarPath
        } else {
            do {
                tarPath = try await archiveClient.exportRootfs(container: container)
            } catch let error as ClientArchiveError {
                if case .rootfsNotFound = error {
                    throw Abort(.notFound, reason: error.localizedDescription)
                }
                throw Abort(.internalServerError, reason: "Error committing container \(commit.container): \(error.localizedDescription)")
            }
        }
        defer {
            if layered == nil { try? FileManager.default.removeItem(at: tarPath) }
        }

        let repo = commit.repo?.isEmpty == false ? commit.repo : nil
        let tag = commit.tag?.isEmpty == false ? commit.tag : nil
        let digest: String
        do {
            (_, digest) = try await imageClient.commitImage(
                tarPath: tarPath,
                repo: repo,
                tag: tag,
                comment: commit.comment,
                author: commit.author,
                configJSON: configJSON,
                base: layered?.base,
                platform: platform,
                appleContainerAppSupportUrl: appSupport,
                logger: req.logger
            )
        } catch ClientImageError.digestReferenceNotAllowed(let repo) {
            throw Abort(.badRequest, reason: "cannot commit to \(repo): a digest reference is not a valid target")
        }

        if let broadcaster = req.application.storage[EventBroadcasterKey.self] {
            await broadcaster.broadcast(commitEvent(container: container, imageId: digest, repo: repo, tag: tag, comment: commit.comment))
        }
        return digest
    }

    /// The container's changes as a layer over its image's own layers, as moby commits. Nil —
    /// logged, and committed squashed instead — when the changes cannot be separated from the
    /// image (never started, or the image snapshot is gone) or the image's layers are no
    /// longer all in the store.
    static func changeLayer(
        of container: ContainerSnapshot,
        archiveClient: ClientArchiveProtocol,
        imageClient: ClientImageCommitProtocol,
        appSupport: URL,
        logger: Logger
    ) async -> (layer: CommitChangeLayer, base: CommitBase)? {
        let layer: CommitChangeLayer
        do {
            guard let exported = try await archiveClient.exportChangeLayer(container: container) else {
                logger.info("Committing \(container.id) as a single squashed layer: its image snapshot is unavailable")
                return nil
            }
            layer = exported
        } catch {
            logger.warning("Committing \(container.id) as a single squashed layer: \(error)")
            return nil
        }
        do {
            let base = try await imageClient.commitBase(manifestDigest: layer.baseManifestDigest, appleContainerAppSupportUrl: appSupport)
            return (layer, base)
        } catch {
            try? FileManager.default.removeItem(at: layer.tarPath)
            logger.warning("Committing \(container.id) as a single squashed layer: base image \(layer.baseManifestDigest) is incomplete: \(error)")
            return nil
        }
    }

    /// moby's container `commit` event: the comment, the new image's id, and the reference it
    /// was tagged with (empty for an untagged commit). podman logs a `commit` too.
    static func commitEvent(container: ContainerSnapshot, imageId: String, repo: String?, tag: String?, comment: String?) -> DockerEvent {
        let imageRef = repo.map { "\($0):\(tag ?? "latest")" } ?? ""
        return DockerEvent.containerEvent(
            "commit", container: container,
            extraAttributes: ["comment": comment ?? "", "imageID": imageId, "imageRef": imageRef]
        )
    }

    /// The user the container runs as, unless it is the root default Apple records for a
    /// container created without one — which says nothing the image should keep.
    static func commitUser(_ user: ProcessConfiguration.User) -> String? {
        switch user {
        case .raw(let name):
            return name.isEmpty ? nil : name
        case .id(let uid, let gid):
            return uid == 0 && gid == 0 ? nil : "\(uid):\(gid)"
        }
    }
}

struct RESTCommitResponse: Content {
    let Id: String
}
