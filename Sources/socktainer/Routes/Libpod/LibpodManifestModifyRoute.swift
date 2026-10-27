import ContainerizationError
import Vapor

/// `PUT /libpod/manifests/{name}` — real podman's unified add/remove/annotate endpoint
/// (`ManifestModifyOptions{Operation: "update"|"remove"|"annotate", Images: [...]}`).
/// "annotate" sets a member's platform/annotations, or the index's own annotations
/// (`--index`); see `ManifestAnnotation`.
///
/// Real podman (`pkg/bindings/manifests`'s `Modify`) sends `operation`/`images`/etc. as
/// query parameters (`images` repeated once per image, like `platform` on `/build` — see
/// `allQueryValues`), NOT as a decodable request body: it does send a JSON body too, but
/// without a `Content-Type` header, so `req.content.decode` fails with "Can't decode data
/// without a content type" before ever reaching the body's actual content. The query
/// string carries the same data and is what's actually decoded here.
struct RESTManifestModifyQuery: Content {
    let operation: String?
}

struct LibpodManifestModifyRoute: RouteCollection {
    let client: ClientManifestServiceProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.PUT, pattern: "/libpod/manifests/{name:.*}", use: LibpodManifestModifyRoute.handler(client: client))
    }

    static func handler(client: ClientManifestServiceProtocol) -> @Sendable (Request) async throws -> RESTManifestIDResponse {
        { req in
            guard let name = req.parameters.get("name"), !name.isEmpty else {
                throw Abort(.badRequest, reason: "Missing manifest list name")
            }
            let query: RESTManifestModifyQuery
            do {
                query = try req.query.decode(RESTManifestModifyQuery.self)
            } catch {
                throw Abort(.badRequest, reason: "Invalid query parameters: \(error)")
            }
            let images = allQueryValues(named: "images", from: req.url.query)

            do {
                switch query.operation {
                case "remove":
                    guard !images.isEmpty else {
                        throw Abort(.badRequest, reason: "remove requires at least one image digest")
                    }
                    // Validate every requested digest is a current member BEFORE removing
                    // any of them — `removeDigest` re-tags after each single removal, so
                    // looping it directly would leave the manifest list partially modified
                    // (the first N-1 digests already removed) if a LATER digest in the same
                    // request turns out to be invalid, with no way for the caller to tell.
                    let currentDigests = Set(try await client.inspect(name: name).manifests.map(\.digest))
                    var normalizedDigests: [String] = []
                    var seenDigests = Set<String>()
                    for digest in images {
                        let normalized = try ClientManifestService.normalizedDigest(digest)
                        guard currentDigests.contains(normalized) else {
                            throw Abort(.badRequest, reason: "\(normalized) is not a member of \(name)")
                        }
                        // A duplicate in the SAME request would otherwise pass this
                        // membership check (it IS currently a member) but then fail on its
                        // second removal attempt below (no longer a member after the
                        // first) — partially modifying the list for the exact reason this
                        // pre-check exists in the first place.
                        guard seenDigests.insert(normalized).inserted else {
                            throw Abort(.badRequest, reason: "\(normalized) is requested more than once")
                        }
                        normalizedDigests.append(normalized)
                    }
                    let result = try await client.removeDigests(name: name, digests: normalizedDigests)
                    return RESTManifestIDResponse(ID: result)
                case "annotate":
                    // The platform/annotation fields only travel in the JSON body.
                    let body = req.body.data.map { Data(buffer: $0) } ?? Data()
                    let (annotation, bodyImages) = try ManifestAnnotation.decode(podmanBody: body)
                    // podman sends `[""]` for `--index`; an empty list means the same.
                    let instances = images.isEmpty ? (bodyImages.isEmpty ? [""] : bodyImages) : images
                    var result = ""
                    for instance in instances {
                        result = try await client.annotate(name: name, instance: instance, annotation: annotation, logger: req.logger)
                    }
                    return RESTManifestIDResponse(ID: result)
                case "update", nil, "":
                    guard !images.isEmpty else {
                        throw Abort(.badRequest, reason: "update requires at least one image")
                    }
                    let result = try await client.add(name: name, images: images, logger: req.logger)
                    return RESTManifestIDResponse(ID: result)
                case .some(let unknown):
                    throw Abort(.badRequest, reason: "Unknown manifest modify operation: \(unknown)")
                }
            } catch ClientImageError.notFound(let id) {
                throw Abort(.badRequest, reason: "No such image: \(id)")
            } catch is ClientManifestError {
                throw Abort(.notFound, reason: "No such manifest list: \(name)")
            } catch let error as ContainerizationError where error.code == .invalidArgument {
                throw Abort(.badRequest, reason: error.message)
            }
        }
    }
}
