import Foundation
import Vapor

/// What a pod does to one of its members.
enum LibpodPodAction: Sendable, Equatable {
    case start
    case stop(timeout: Int?)
    case restart(timeout: Int?)
    case kill(signal: String)
    case remove(force: Bool)
}

/// The container-side effects the pod routes need, kept separate from the routes so the
/// pod logic can be tested without a container runtime.
struct LibpodPodRuntime: Sendable {
    /// Every container that carries the pod label, whichever pod it belongs to.
    var members: @Sendable (Request) async throws -> [LibpodPodMember]
    /// Applies `action` to one container (by ID).
    var perform: @Sendable (Request, LibpodPodAction, String) async throws -> Void
    /// Creates the pod's network unless it already exists.
    var ensureNetwork: @Sendable (Request, PodRecord) async throws -> Void
    /// Removes the pod's network (only called for networks socktainer created).
    var removeNetwork: @Sendable (Request, String) async throws -> Void
}

extension LibpodPodRuntime {
    /// The real runtime: member operations go through the Docker-compat handlers, so a pod
    /// start/stop/remove behaves exactly like the per-container calls (events, DNS,
    /// healthchecks, auto-remove).
    static func live(client: ClientContainerProtocol, networkClient: ClientNetworkProtocol) -> LibpodPodRuntime {
        LibpodPodRuntime(
            members: { req in
                let sub = subrequest(
                    of: req, path: "/containers/json", id: nil,
                    query: [
                        "all": "true", "filters": #"{"label":["\#(LibpodPodSchema.podLabel)"]}"#,
                    ])
                return try await ContainerListRoute.handler(client: client)(sub).compactMap { summary in
                    guard let pod = summary.Labels[LibpodPodSchema.podLabel] else { return nil }
                    let name = summary.Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? summary.Id
                    return LibpodPodMember(id: summary.Id, name: name, state: summary.State.lowercased(), podID: pod)
                }
            },
            perform: { req, action, id in
                switch action {
                case .start:
                    _ = try await ContainerStartRoute.handler(client: client)(subrequest(of: req, path: "/containers/\(id)/start", id: id))
                case .stop(let timeout):
                    let query = timeout.map { ["t": String($0)] } ?? [:]
                    _ = try await ContainerStopRoute.handler(client: client)(subrequest(of: req, path: "/containers/\(id)/stop", id: id, query: query))
                case .restart(let timeout):
                    let query = timeout.map { ["t": String($0)] } ?? [:]
                    _ = try await ContainerRestartRoute.handler(client: client)(
                        subrequest(of: req, path: "/containers/\(id)/restart", id: id, query: query))
                case .kill(let signal):
                    let response = try await ContainerKillRoute.handler(client: client)(
                        subrequest(of: req, path: "/containers/\(id)/kill", id: id, query: ["signal": signal]))
                    guard (200..<300).contains(Int(response.status.code)) else {
                        throw Abort(response.status, reason: response.body.string ?? "kill failed")
                    }
                case .remove(let force):
                    _ = try await ContainerDeleteRoute.handler(client: client)(
                        subrequest(of: req, path: "/containers/\(id)", id: id, query: ["force": force ? "true" : "false"]))
                }
            },
            ensureNetwork: { req, pod in
                guard let network = pod.network, try await networkClient.getNetwork(id: network, logger: req.logger) == nil else { return }
                guard pod.ownsNetwork else {
                    throw Abort(.notFound, reason: "network \(network) of pod \(pod.name) not found: network not found")
                }
                do {
                    _ = try await NetworkCreateRoute.createPinned(
                        client: networkClient, name: network, labels: [LibpodPodSchema.podLabel: pod.id], ipam: nil, mode: .nat,
                        logger: req.logger)
                } catch  where "\(error)".lowercased().contains("already exists") {
                    // Another member of the same pod created it first.
                }
            },
            removeNetwork: { req, network in
                // Through the Docker-compat handler, which first removes the network's DNS sidecar.
                _ = try await NetworkDeleteRoute(client: networkClient).handler(subrequest(of: req, path: "/networks/\(network)", id: network))
            }
        )
    }

    /// A body-less request addressed to a Docker-compat handler.
    private static func subrequest(of req: Request, path: String, id: String?, query: [String: String] = [:]) -> Request {
        var components = URLComponents()
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        let sub = Request(
            application: req.application, method: req.method, url: URI(string: components.string ?? path), version: req.version,
            headers: req.headers, collectedBody: nil, remoteAddress: req.remoteAddress, logger: req.logger, on: req.eventLoop)
        if let id { sub.parameters.set("id", to: id) }
        return sub
    }
}

/// podman's `/libpod/pods/*` API.
///
/// A pod here is a named group of containers recorded by socktainer; see `PodRecord` for
/// what members can and cannot share on Apple Container.
struct LibpodPodRoute: RouteCollection {
    let runtime: LibpodPodRuntime
    var store: PodStore = .shared

    func boot(routes: RoutesBuilder) throws {
        let runtime = self.runtime
        let store = self.store
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/create", use: Self.create(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/pods/json", use: Self.list(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/prune", use: Self.prune(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/pods/{name}/exists", use: Self.exists(store: store))
        try routes.registerVersionedRoute(.GET, pattern: "/libpod/pods/{name}/json", use: Self.inspect(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/{name}/start", use: Self.start(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/{name}/stop", use: Self.stop(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/{name}/restart", use: Self.restart(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.POST, pattern: "/libpod/pods/{name}/kill", use: Self.kill(store: store, runtime: runtime))
        try routes.registerVersionedRoute(.DELETE, pattern: "/libpod/pods/{name}", use: Self.remove(store: store, runtime: runtime))
    }

    // MARK: Helpers

    /// podman's `utils.PodNotFound`: the client recognises a missing pod by `no such pod`.
    static func notFound(_ name: String) -> Abort {
        Abort(.notFound, reason: "no pod with name or ID \(name) found: no such pod")
    }

    static func lookup(_ req: Request, store: PodStore) async throws -> PodRecord {
        let name = req.parameters.get("name") ?? ""
        guard let pod = await store.resolve(name) else { throw notFound(name) }
        return pod
    }

    static func members(of pod: PodRecord, _ req: Request, runtime: LibpodPodRuntime) async throws -> [LibpodPodMember] {
        try await runtime.members(req).filter { $0.podID == pod.id }
    }

    /// Runs `action` on each container, collecting failures rather than stopping at the first.
    static func apply(
        _ action: LibpodPodAction, to members: [LibpodPodMember], _ req: Request, runtime: LibpodPodRuntime
    ) async -> [String] {
        var errors: [String] = []
        for member in members {
            do {
                try await runtime.perform(req, action, member.id)
            } catch let abort as AbortError {
                errors.append("\(member.name): \(abort.reason)")
            } catch {
                errors.append("\(member.name): \(error)")
            }
        }
        return errors
    }

    /// The report the lifecycle calls answer with: 200 when every member succeeded, else 409
    /// with podman's `PodConflictErrorModel` (`Errs` as strings, which the client decodes).
    static func report(_ pod: PodRecord, errors: [String], rawInput: String? = nil) throws -> Response {
        var body: [String: Any] = ["Id": pod.id, "Errs": errors]
        if let rawInput { body["RawInput"] = rawInput }
        return try LibpodAdapter.jsonResponse(body, status: errors.isEmpty ? .ok : .conflict)
    }

    static func timeout(_ req: Request) -> Int? {
        req.query[Int.self, at: "timeout"] ?? req.query[Int.self, at: "t"]
    }

    // MARK: Handlers

    static func create(store: PodStore) -> @Sendable (Request) async throws -> Response {
        { req in
            let request: LibpodPodSchema.CreateRequest
            do {
                request = try LibpodPodSchema.createRequest(fromSpec: try await LibpodAdapter.jsonObjectBody(of: req))
            } catch let error as LibpodPodSchema.SpecError {
                throw Abort(.badRequest, reason: error.description)
            }
            let pod: PodRecord
            do {
                pod = try await store.create(name: request.name) { id, name in LibpodPodSchema.record(request, id: id, name: name) }
            } catch let error as PodStoreError {
                switch error {
                case .nameInUse: throw Abort(.conflict, reason: error.description)
                case .invalidName: throw Abort(.badRequest, reason: error.description)
                }
            }
            return try LibpodAdapter.jsonResponse(["Id": pod.id], status: .created)
        }
    }

    static func exists(store: PodStore) -> @Sendable (Request) async throws -> Response {
        { req in
            _ = try await lookup(req, store: store)
            return Response(status: .noContent)
        }
    }

    static func inspect(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            return try LibpodAdapter.jsonResponse(LibpodPodSchema.inspect(pod, members: try await members(of: pod, req, runtime: runtime)))
        }
    }

    static func list(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            var filters: [String: [String]] = [:]
            if let raw = req.query[String.self, at: "filters"], !raw.isEmpty {
                guard let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
                    throw Abort(.badRequest, reason: "failed to parse filters \(raw)")
                }
                filters = decoded
            }
            let all = try await runtime.members(req)
            var reports: [[String: Any]] = []
            for pod in await store.all() {
                let members = all.filter { $0.podID == pod.id }
                do {
                    guard try LibpodPodSchema.matches(pod, members: members, filters: filters) else { continue }
                } catch {
                    throw Abort(.badRequest, reason: "\(error)")
                }
                reports.append(LibpodPodSchema.listReport(pod, members: members))
            }
            return try LibpodAdapter.jsonResponse(reports)
        }
    }

    static func start(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            let members = try await members(of: pod, req, runtime: runtime)
            if LibpodPodSchema.status(memberStates: members.map(\.state)) == "Running" {
                return Response(status: .notModified)
            }
            // The pod network can have been reaped as empty while every member was stopped.
            try await runtime.ensureNetwork(req, pod)
            let errors = await apply(.start, to: members.filter { $0.state != "running" }, req, runtime: runtime)
            return try report(pod, errors: errors, rawInput: req.parameters.get("name"))
        }
    }

    static func stop(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            let members = try await members(of: pod, req, runtime: runtime)
            if LibpodPodSchema.status(memberStates: members.map(\.state)) != "Running" && !members.contains(where: { $0.state == "running" }) {
                return Response(status: .notModified)
            }
            let errors = await apply(.stop(timeout: timeout(req)), to: members.filter { $0.state == "running" }, req, runtime: runtime)
            return try report(pod, errors: errors, rawInput: req.parameters.get("name"))
        }
    }

    static func restart(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            let members = try await members(of: pod, req, runtime: runtime)
            try await runtime.ensureNetwork(req, pod)
            let errors = await apply(.restart(timeout: timeout(req)), to: members, req, runtime: runtime)
            return try report(pod, errors: errors)
        }
    }

    static func kill(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            let running = try await members(of: pod, req, runtime: runtime).filter { $0.state == "running" }
            guard !running.isEmpty else {
                throw Abort(.conflict, reason: "cannot kill a pod with no running containers: \(pod.id)")
            }
            let signal = req.query[String.self, at: "signal"] ?? "SIGKILL"
            let errors = await apply(.kill(signal: signal), to: running, req, runtime: runtime)
            return try report(pod, errors: errors)
        }
    }

    /// Removes the pod's containers, then the pod and the network made for it. Without
    /// `force`, a pod with running members is refused, as podman does.
    static func removePod(
        _ pod: PodRecord, members: [LibpodPodMember], force: Bool, _ req: Request, store: PodStore, runtime: LibpodPodRuntime
    ) async throws -> [String: Any] {
        if !force, let running = members.first(where: { $0.state == "running" }) {
            throw Abort(
                .conflict,
                reason:
                    "pod \(pod.id) has containers that are not ready to be removed: cannot remove container \(running.id) as it is running - running or paused containers cannot be removed without force: container state improper"
            )
        }
        var removed: [String: Any] = [:]
        var failures: [String] = []
        for member in members {
            do {
                try await runtime.perform(req, .remove(force: force), member.id)
                removed[member.id] = NSNull()
            } catch let abort as AbortError {
                failures.append("\(member.name): \(abort.reason)")
            } catch {
                failures.append("\(member.name): \(error)")
            }
        }
        guard failures.isEmpty else {
            throw Abort(.internalServerError, reason: "removing pod \(pod.id) containers: \(failures.joined(separator: "; "))")
        }
        if pod.ownsNetwork, let network = pod.network {
            do {
                try await runtime.removeNetwork(req, network)
            } catch {
                // The network may already be gone (reaped while empty); the pod still goes.
                req.logger.warning("pod \(pod.name): could not remove network \(network): \(error)")
            }
        }
        try await store.remove(id: pod.id)
        return ["Id": pod.id, "RemovedCtrs": removed, "Err": NSNull()]
    }

    static func remove(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let pod = try await lookup(req, store: store)
            let force = req.query[Bool.self, at: "force"] ?? false
            let members = try await members(of: pod, req, runtime: runtime)
            return try LibpodAdapter.jsonResponse(try await removePod(pod, members: members, force: force, req, store: store, runtime: runtime))
        }
    }

    /// Removes every pod whose members have all stopped (podman's `Exited`/`Stopped`).
    static func prune(store: PodStore, runtime: LibpodPodRuntime) -> @Sendable (Request) async throws -> Response {
        { req in
            let all = try await runtime.members(req)
            var reports: [[String: Any]] = []
            for pod in await store.all() {
                let members = all.filter { $0.podID == pod.id }
                guard ["Exited", "Stopped"].contains(LibpodPodSchema.status(memberStates: members.map(\.state))) else { continue }
                do {
                    _ = try await removePod(pod, members: members, force: true, req, store: store, runtime: runtime)
                    reports.append(["Id": pod.id, "Err": NSNull()])
                } catch {
                    req.logger.warning("pod prune: \(pod.name): \(error)")
                }
            }
            return try LibpodAdapter.jsonResponse(reports)
        }
    }
}
