import Foundation
import Vapor

struct LibpodImagePullRoute: RouteCollection {
    let client: ClientImageProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/images/pull", use: LibpodImagePullRoute.handler(client: client))
    }

    static func handler(client: ClientImageProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            let reference: String = req.query["reference"] ?? ""
            let platformString: String? = req.query["platform"]

            let (image, tag) = parseReference(reference)

            let platform: Platform
            if let platformString, !platformString.isEmpty {
                do {
                    platform = try platformOrThrow(platformString)
                } catch {
                    let response = Response(status: .internalServerError)
                    response.headers.add(name: .contentType, value: "application/json")
                    response.body = .init(string: "{\"message\": \"Failed to parse platform\"}\n")
                    return response
                }
            } else {
                platform = currentPlatform()
            }

            let response = Response()
            response.headers.add(name: .contentType, value: "application/json")
            let progressStream = try await client.pull(
                image: image, tag: tag, platform: platform, logger: req.logger)

            response.body = .init(stream: { writer in
                Task {
                    do {
                        for try await progress in progressStream {
                            let json = "{\"status\": \"\(progress.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                            _ = writer.write(.buffer(ByteBuffer(string: json + "\n")))
                        }
                        _ = writer.write(.end)
                    } catch {
                        _ = writer.write(.buffer(ByteBuffer(string: "{\"error\": \"\(error.localizedDescription)\"}\n")))
                        _ = writer.write(.error(error))
                    }
                }
            })
            return response
        }
    }

    private static func parseReference(_ reference: String) -> (image: String, tag: String) {
        let decoded = reference.removingPercentEncoding ?? reference
        if let atIndex = decoded.lastIndex(of: ":"),
            !decoded[atIndex...].contains("/")
        {
            let image = String(decoded[..<atIndex])
            let tag = String(decoded[decoded.index(after: atIndex)...])
            return (image, tag)
        }
        return (decoded, "")
    }
}
