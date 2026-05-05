import Foundation
import Vapor

struct LibpodContainerCreateRoute: RouteCollection {
    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/containers/create", use: LibpodContainerCreateRoute.handler(client: client))
    }

    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> RESTContainerCreate {
        { req in
            let bodyData = try await req.body.collect().get()!
            let libpodBody = try JSONDecoder().decode(
                LibpodContainerCreateRequest.self,
                from: bodyData.getData(at: 0, length: bodyData.readableBytes)!
            )

            let dockerBody = CreateContainerRequest(
                Image: libpodBody.image,
                Hostname: nil,
                Domainname: nil,
                User: nil,
                AttachStdin: nil,
                AttachStdout: nil,
                AttachStderr: nil,
                PortSpecs: nil,
                Tty: nil,
                OpenStdin: nil,
                StdinOnce: nil,
                Env: nil,
                Cmd: libpodBody.command,
                Healthcheck: nil,
                ArgsEscaped: nil,
                Entrypoint: nil,
                Volumes: nil,
                WorkingDir: nil,
                MacAddress: nil,
                OnBuild: nil,
                NetworkDisabled: nil,
                ExposedPorts: nil,
                StopSignal: nil,
                StopTimeout: nil,
                HostConfig: nil,
                Labels: nil,
                Shell: nil,
                NetworkingConfig: nil
            )

            let containerName: String? = libpodBody.name ?? req.query["name"]

            var path = "/containers/create"
            if let name = containerName {
                let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                path += "?name=\(encoded)"
            }
            req.url = URI(string: path)

            try req.content.encode(dockerBody, as: .json)

            let dockerHandler = ContainerCreateRoute.handler(client: client)
            return try await dockerHandler(req)
        }
    }
}
