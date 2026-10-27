import Foundation
import Vapor

/// Query of `POST /libpod/commit` (podman's `CommitContainer` handler). Same fields as
/// Docker's plus `stream`, which podman's CLI sets unless `--quiet`.
struct RESTLibpodCommitQuery: Content {
    let container: String?
    let repo: String?
    let tag: String?
    let comment: String?
    let author: String?
    let stream: Bool?
}

struct LibpodCommitRoute: RouteCollection {
    let containerClient: ClientContainerProtocol
    let archiveClient: ClientArchiveProtocol
    let imageClient: ClientImageCommitProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/libpod/commit",
            use: LibpodCommitRoute.handler(containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient))
    }

    static func handler(
        containerClient: ClientContainerProtocol,
        archiveClient: ClientArchiveProtocol,
        imageClient: ClientImageCommitProtocol
    ) -> @Sendable (Vapor.Request) async throws -> Response {
        { req in
            let query = try req.query.decode(RESTLibpodCommitQuery.self)
            guard let container = query.container, !container.isEmpty else {
                throw Abort(.badRequest, reason: "Missing container query parameter")
            }
            let commit = CommitRoute.CommitRequest(
                container: container,
                repo: query.repo,
                tag: query.tag,
                comment: query.comment,
                author: query.author,
                changes: decodeChanges(allQueryValues(named: "changes", from: req.url.query)),
                config: req.body.data.map { Data(buffer: $0) }
            )
            let id = try await CommitRoute.perform(
                commit, req: req, containerClient: containerClient, archiveClient: archiveClient, imageClient: imageClient)
            // podman reports image ids as bare hex.
            let hexId = id.hasPrefix("sha256:") ? String(id.dropFirst("sha256:".count)) : id

            guard query.stream == true else {
                return try await RESTCommitResponse(Id: hexId).encodeResponse(status: .ok, for: req)
            }
            // The streaming client reads `{"stream": ...}` lines and takes the first one
            // that starts with 12 hex digits as the new image's id.
            let line = try JSONEncoder().encode(["stream": hexId + "\n"])
            let response = Response(status: .ok, body: .init(data: line + Data("\n".utf8)))
            response.headers.contentType = .json
            return response
        }
    }

    /// podman's `util.DecodeChanges`: one instruction per line, and its documented
    /// `INSTRUCTION=value` shorthand (`CMD=/bin/sh`) turned into Dockerfile syntax.
    static func decodeChanges(_ changes: [String]) -> [String] {
        changes.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }.compactMap { line in
            let change = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !change.isEmpty else { return nil }
            guard let equal = change.firstIndex(of: "=") else { return change }
            if let space = change.firstIndex(where: \.isWhitespace), space < equal {
                return change
            }
            return change.replacingCharacters(in: equal...equal, with: " ")
        }
    }
}
