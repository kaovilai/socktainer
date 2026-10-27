import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

/// Records what the pod routes asked the container runtime to do, and answers member
/// listings from a fixed set of containers whose state follows those actions.
private actor FakePodRuntime {
    var containers: [LibpodPodMember] = []
    var actions: [String] = []
    var networks: Set<String> = []
    var failing: Set<String> = []

    func add(_ member: LibpodPodMember) { containers.append(member) }
    func fail(_ id: String) { failing.insert(id) }

    func perform(_ action: LibpodPodAction, _ id: String) throws {
        actions.append("\(action) \(id)")
        if failing.contains(id) { throw Abort(.internalServerError, reason: "boom") }
        guard let index = containers.firstIndex(where: { $0.id == id }) else { return }
        let member = containers[index]
        func set(_ state: String) {
            containers[index] = LibpodPodMember(id: member.id, name: member.name, state: state, podID: member.podID)
        }
        switch action {
        case .start, .restart: set("running")
        case .stop, .kill: set("exited")
        case .remove: containers.remove(at: index)
        case .pause: set("paused")
        case .unpause: set("running")
        }
    }

    /// One `ps` row per member, so a merged table shows which members were asked.
    func top(_ id: String, _ psArgs: String?) throws -> RESTContainerTop {
        actions.append("top \(id) \(psArgs ?? "-")")
        if failing.contains(id) { throw Abort(.conflict, reason: "container \(id) is not running") }
        return RESTContainerTop(Titles: ["PID", "COMMAND"], Processes: [["1", "sleep-\(id)"]])
    }

    func stats(_ id: String) throws -> LibpodPodMemberStats {
        actions.append("stats \(id)")
        if failing.contains(id) { throw Abort(.conflict, reason: "container \(id) is not running") }
        return LibpodPodMemberStats(
            cpuPercent: 1.5, memUsage: 12_500_000, memLimit: 1_073_741_824, memPercent: 1.164, netInput: 1_000, netOutput: 0,
            blockInput: 0, blockOutput: 0, pids: 3)
    }

    func ensure(_ pod: PodRecord) { if let network = pod.network { networks.insert(network) } }
    func removeNetwork(_ name: String) {
        networks.remove(name)
        actions.append("rmnet \(name)")
    }

    nonisolated var runtime: LibpodPodRuntime {
        LibpodPodRuntime(
            members: { _ in await self.containers },
            perform: { _, action, id in try await self.perform(action, id) },
            ensureNetwork: { _, pod in await self.ensure(pod) },
            removeNetwork: { _, name in await self.removeNetwork(name) },
            top: { _, id, psArgs in try await self.top(id, psArgs) },
            stats: { _, id in try await self.stats(id) }
        )
    }
}

@Suite("Libpod pod routes")
struct LibpodPodRouteTests {
    private func withPodApp(
        store: PodStore, fake: FakePodRuntime, _ test: @escaping (Application) async throws -> Void
    ) async throws {
        try await withApp(configure: { _ in }) { app in
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodPodRoute(runtime: fake.runtime, store: store))
            try await test(app)
        }
    }

    private func createPod(_ app: Application, _ body: String) async throws -> String {
        var id = ""
        try await app.testing().test(
            .POST, "/v5.0.0/libpod/pods/create",
            beforeRequest: { req in req.body = ByteBuffer(string: body) },
            afterResponse: { res async in
                #expect(res.status == .created)
                id = (try? JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])?["Id"] as? String ?? ""
            })
        return id
    }

    private func json(_ res: TestingHTTPResponse) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(buffer: res.body), options: [.fragmentsAllowed])
    }

    @Test("create answers 201 with the ID; a taken name is 409; pod-level ports are 400")
    func create() async throws {
        let store = PodStore()
        try await withPodApp(store: store, fake: FakePodRuntime()) { app in
            let id = try await createPod(app, #"{"name":"pd-p1"}"#)
            #expect(id.count == 64)
            try await app.testing().test(
                .POST, "/v5.0.0/libpod/pods/create", beforeRequest: { $0.body = ByteBuffer(string: #"{"name":"pd-p1"}"#) }
            ) { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("pod already exists"))
            }
            try await app.testing().test(
                .POST, "/v5.0.0/libpod/pods/create",
                beforeRequest: { $0.body = ByteBuffer(string: #"{"name":"pd-p2","portmappings":[{"container_port":80}]}"#) }
            ) { res async in
                #expect(res.status == .badRequest)
            }
        }
        #expect(await store.all().map(\.name) == ["pd-p1"])
    }

    @Test("exists is 204 for a pod and a 404 the podman client reads as 'no such pod'")
    func exists() async throws {
        try await withPodApp(store: PodStore(), fake: FakePodRuntime()) { app in
            _ = try await createPod(app, #"{"name":"pd-e"}"#)
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-e/exists") { res async in
                #expect(res.status == .noContent)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/missing/exists") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such pod"))
            }
        }
    }

    @Test("inspect and list show the pod's members and status, and list honours filters")
    func inspectAndList() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-i","labels":{"tier":"web"}}"#)
            _ = try await createPod(app, #"{"name":"pd-other"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "pd-a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "loose", state: "running", podID: "elsewhere"))

            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-i/json") { res async in
                #expect(res.status == .ok)
                let body = json(res) as? [String: Any]
                #expect(body?["Id"] as? String == id)
                #expect(body?["State"] as? String == "Running")
                #expect(body?["NumContainers"] as? Int == 1)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/json") { res async in
                let pods = json(res) as? [[String: Any]]
                #expect(pods?.count == 2)
            }
            let filter = #"{"label":["tier=web"]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/json?filters=\(filter)") { res async in
                let pods = json(res) as? [[String: Any]]
                #expect(pods?.map { $0["Name"] as? String } == ["pd-i"])
                #expect((pods?.first?["Containers"] as? [[String: Any]])?.count == 1)
            }
        }
    }

    @Test("start starts the members that are not running, and is 304 when all already run")
    func start() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-s"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "created", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "running", podID: id))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-s/start") { res async in
                #expect(res.status == .ok)
                #expect((json(res) as? [String: Any])?["Errs"] as? [String] == [])
            }
            #expect(await fake.actions == ["start c1"])
            #expect(await fake.networks == ["pod-pd-s"])
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-s/start") { res async in
                #expect(res.status == .notModified)
            }
        }
    }

    @Test("stop stops running members with the given timeout, and is 304 for a stopped pod")
    func stop() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-st"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "exited", podID: id))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-st/stop?timeout=3") { res async in
                #expect(res.status == .ok)
            }
            #expect(await fake.actions == ["stop(timeout: Optional(3)) c1"])
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-st/stop") { res async in
                #expect(res.status == .notModified)
            }
        }
    }

    @Test("a member that fails makes the call a 409 listing it in Errs")
    func memberFailure() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-f"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "created", podID: id))
            await fake.fail("c1")
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-f/start") { res async in
                #expect(res.status == .conflict)
                let errs = (json(res) as? [String: Any])?["Errs"] as? [String]
                #expect(errs?.first?.contains("boom") == true)
            }
        }
    }

    @Test("kill signals running members and is 409 when none run")
    func kill() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-k"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-k/kill?signal=SIGTERM") { res async in
                #expect(res.status == .ok)
            }
            #expect(await fake.actions == [#"kill(signal: "SIGTERM") c1"#])
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-k/kill") { res async in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("restart restarts every member")
    func restart() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-r"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "exited", podID: id))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-r/restart") { res async in
                #expect(res.status == .ok)
            }
            #expect(await fake.actions.count == 2)
        }
    }

    @Test("rm refuses running members without force; with force removes members, network and pod")
    func remove() async throws {
        let fake = FakePodRuntime()
        let store = PodStore()
        try await withPodApp(store: store, fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-rm"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            try await app.testing().test(.DELETE, "/v5.0.0/libpod/pods/pd-rm") { res async in
                #expect(res.status == .conflict)
            }
            #expect(await fake.actions.isEmpty)
            try await app.testing().test(.DELETE, "/v5.0.0/libpod/pods/pd-rm?force=true") { res async in
                #expect(res.status == .ok)
                let body = json(res) as? [String: Any]
                #expect(body?["Id"] as? String == id)
                #expect((body?["RemovedCtrs"] as? [String: Any])?.keys.sorted() == ["c1"])
            }
            #expect(await fake.actions == ["remove(force: true) c1", "rmnet pod-pd-rm"])
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-rm/exists") { res async in
                #expect(res.status == .notFound)
            }
        }
        #expect(await store.all().isEmpty)
    }

    @Test("rm of a pod whose members all stopped needs no force (podman-compose down)")
    func removeStopped() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pod_proj","no_infra":true,"shared_namespaces":[""]}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "exited", podID: id))
            try await app.testing().test(.DELETE, "/v5.0.0/libpod/pods/pod_proj") { res async in
                #expect(res.status == .ok)
            }
            // The pod made no network, so none is removed.
            #expect(await fake.actions == ["remove(force: false) c1"])
        }
    }

    @Test("prune removes pods whose members all exited and keeps the rest")
    func prune() async throws {
        let fake = FakePodRuntime()
        let store = PodStore()
        try await withPodApp(store: store, fake: fake) { app in
            let exited = try await createPod(app, #"{"name":"pd-x"}"#)
            let running = try await createPod(app, #"{"name":"pd-y"}"#)
            _ = try await createPod(app, #"{"name":"pd-empty"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "exited", podID: exited))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "running", podID: running))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/prune") { res async in
                #expect(res.status == .ok)
                let reports = json(res) as? [[String: Any]]
                #expect(reports?.map { $0["Id"] as? String } == [exited])
            }
        }
        #expect(await store.all().map(\.name).sorted() == ["pd-empty", "pd-y"])
    }

    @Test("pause pauses only running members and unpause only paused ones, answering podman's report")
    func pauseAndUnpause() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-pz"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "exited", podID: id))
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-pz/pause") { res async in
                #expect(res.status == .ok)
                let body = json(res) as? [String: Any]
                #expect(body?["Id"] as? String == id)
                #expect(body?["Errs"] as? [String] == [])
            }
            #expect(await fake.actions == ["pause c1"])
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-pz/unpause") { res async in
                #expect(res.status == .ok)
            }
            #expect(await fake.actions == ["pause c1", "unpause c1"])
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/missing/pause") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such pod"))
            }
        }
    }

    @Test("a member that cannot be paused makes pause a 409 naming it")
    func pauseFailure() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-pf"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.fail("c1")
            try await app.testing().test(.POST, "/v5.0.0/libpod/pods/pd-pf/pause") { res async in
                #expect(res.status == .conflict)
                let errs = (json(res) as? [String: Any])?["Errs"] as? [String]
                #expect(errs == ["pausing container a: boom"])
            }
        }
    }

    @Test("top merges the processes of every running member under one header")
    func top() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-top"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "exited", podID: id))
            await fake.add(LibpodPodMember(id: "c3", name: "c", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c4", name: "d", state: "running", podID: "elsewhere"))
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-top/top?ps_args=pid,args") { res async in
                #expect(res.status == .ok)
                let body = json(res) as? [String: Any]
                #expect(body?["Titles"] as? [String] == ["PID", "COMMAND"])
                #expect(body?["Processes"] as? [[String]] == [["1", "sleep-c1"], ["1", "sleep-c3"]])
            }
            #expect(await fake.actions == ["top c1 pid,args", "top c3 pid,args"])
        }
    }

    @Test("top uses podman's default descriptors, skips members that stopped, and rejects what is not a descriptor")
    func topDefaultsAndErrors() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-top2"}"#)
            await fake.add(LibpodPodMember(id: "c1", name: "a", state: "running", podID: id))
            await fake.fail("c1")
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-top2/top") { res async in
                #expect(res.status == .ok)
                let body = json(res) as? [String: Any]
                #expect(body?["Titles"] as? [String] == ["USER", "PID", "PPID", "%CPU", "ELAPSED", "TTY", "TIME", "COMMAND"])
                #expect((body?["Processes"] as? [[String]])?.isEmpty == true)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-top2/top?ps_args=-ef") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("unknown descriptor"))
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/pd-top2/top?delay=0") { res async in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/missing/top") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("stats reports each running or paused member of the pods asked for, in podman's format")
    func stats() async throws {
        let fake = FakePodRuntime()
        try await withPodApp(store: PodStore(), fake: fake) { app in
            let id = try await createPod(app, #"{"name":"pd-sta"}"#)
            let other = try await createPod(app, #"{"name":"pd-stb"}"#)
            await fake.add(LibpodPodMember(id: "c1aaaaaaaaaaaaaa", name: "a", state: "running", podID: id))
            await fake.add(LibpodPodMember(id: "c2", name: "b", state: "exited", podID: id))
            await fake.add(LibpodPodMember(id: "c3", name: "c", state: "paused", podID: other))
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/stats?namesOrIDs=pd-sta") { res async in
                #expect(res.status == .ok)
                let reports = json(res) as? [[String: String]]
                #expect(reports?.count == 1)
                let report = reports?.first
                #expect(report?["CID"] == "c1aaaaaaaaaa")
                #expect(report?["Pod"] == String(id.prefix(12)))
                #expect(report?["Name"] == "a")
                #expect(report?["CPU"] == "1.50%")
                #expect(report?["MemUsage"] == "12.5MB / 1.074GB")
                #expect(report?["MemUsageBytes"] == "11.92MiB / 1GiB")
                #expect(report?["Mem"] == "1.16%")
                #expect(report?["NetIO"] == "1kB / 0B")
                #expect(report?["BlockIO"] == "-- / --")
                #expect(report?["PIDS"] == "3")
            }
            // Neither names nor `all`: every pod, as podman's v1 compatibility does.
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/stats") { res async in
                #expect((json(res) as? [[String: Any]])?.compactMap { $0["Name"] as? String }.sorted() == ["a", "c"])
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/stats?all=true") { res async in
                #expect((json(res) as? [[String: Any]])?.count == 2)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/stats?all=true&namesOrIDs=pd-sta") { res async in
                #expect(res.status == .internalServerError)
            }
            try await app.testing().test(.GET, "/v5.0.0/libpod/pods/stats?namesOrIDs=missing") { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such pod"))
            }
        }
    }
}

@Suite("Libpod container create in a pod")
struct LibpodContainerCreatePodTests {
    @Test("creating a container in a pod that does not exist is a 404 'no such pod'")
    func unknownPod() async throws {
        let snapshot = try makeContainerSnapshot(nativeId: "pod-create-x", ip: "192.168.65.2", network: "bridge", labels: [:], status: .stopped)
        try await withApp(configure: { _ in }) { app in
            app.middleware.use(DockerErrorMiddleware(), at: .beginning)
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(
                collection: LibpodContainerCreateRoute(client: StaticSnapshotClientMock(snapshot: snapshot), systemConfig: .init(), podStore: PodStore()))
            try await app.testing().test(
                .POST, "/v5.0.0/libpod/containers/create",
                beforeRequest: { $0.body = ByteBuffer(string: #"{"image":"alpine","name":"x","pod":"nope"}"#) }
            ) { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("no such pod"))
            }
        }
    }
}
