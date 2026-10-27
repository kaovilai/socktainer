import Foundation
import Testing

@testable import socktainer

@Suite("Libpod pod schema")
struct LibpodPodSchemaTests {
    private let podID = String(repeating: "ab", count: 32)

    @Test("pod status follows podman's rules over member states")
    func status() {
        #expect(LibpodPodSchema.status(memberStates: []) == "Created")
        #expect(LibpodPodSchema.status(memberStates: ["running", "running"]) == "Running")
        #expect(LibpodPodSchema.status(memberStates: ["running", "exited"]) == "Degraded")
        #expect(LibpodPodSchema.status(memberStates: ["exited", "exited"]) == "Exited")
        #expect(LibpodPodSchema.status(memberStates: ["exited", "created"]) == "Stopped")
        #expect(LibpodPodSchema.status(memberStates: ["created"]) == "Created")
        #expect(LibpodPodSchema.status(memberStates: ["paused"]) == "Paused")
    }

    @Test("a default pod shares its network through a network of its own")
    func defaultPodGetsNetwork() throws {
        let request = try LibpodPodSchema.createRequest(fromSpec: ["name": "My_Pod", "labels": ["a": "b"]])
        let pod = LibpodPodSchema.record(request, id: podID, name: "My_Pod")
        #expect(pod.network == "pod-my-pod")
        #expect(pod.ownsNetwork)
        #expect(pod.sharedNamespaces == ["ipc", "net", "uts"])
        #expect(pod.labels == ["a": "b"])
    }

    @Test("podman-compose's --infra=false --share= pod gets no network")
    func composePodHasNoNetwork() throws {
        let request = try LibpodPodSchema.createRequest(fromSpec: ["name": "pod_proj", "no_infra": true, "shared_namespaces": [""]])
        let pod = LibpodPodSchema.record(request, id: podID, name: "pod_proj")
        #expect(pod.network == nil)
        #expect(!pod.ownsNetwork)
        #expect(pod.sharedNamespaces.isEmpty)

        let unshared = try LibpodPodSchema.createRequest(fromSpec: ["name": "p", "shared_namespaces": [""]])
        #expect(LibpodPodSchema.record(unshared, id: podID, name: "p").network == nil)
        let host = try LibpodPodSchema.createRequest(fromSpec: ["name": "p", "netns": ["nsmode": "host"]])
        #expect(LibpodPodSchema.record(host, id: podID, name: "p").network == nil)
    }

    @Test("a pod told to use an existing network uses it and does not own it")
    func explicitNetwork() throws {
        let request = try LibpodPodSchema.createRequest(fromSpec: ["name": "p", "Networks": ["shared": [String: Any]()]])
        let pod = LibpodPodSchema.record(request, id: podID, name: "p")
        #expect(pod.network == "shared")
        #expect(!pod.ownsNetwork)
    }

    @Test("pod-level published ports are refused, not dropped")
    func portsRefused() {
        #expect(throws: LibpodPodSchema.SpecError.self) {
            _ = try LibpodPodSchema.createRequest(fromSpec: ["name": "p", "portmappings": [["container_port": 80, "host_port": 8080]]])
        }
    }

    @Test("a pod name Apple's network naming rejects falls back to the pod ID")
    func networkNameFallback() {
        #expect(LibpodPodSchema.networkName(podName: "web", podID: podID) == "pod-web")
        #expect(LibpodPodSchema.networkName(podName: String(repeating: "x", count: 70), podID: podID) == "pod-" + podID.prefix(12))
        #expect(LibpodPodSchema.networkName(podName: "a.", podID: podID) == "pod-" + podID.prefix(12))
    }

    @Test("joining a pod labels the container and puts it on the pod network, keeping its own hostname")
    func joinPod() throws {
        let pod = LibpodPodSchema.record(try LibpodPodSchema.createRequest(fromSpec: ["name": "p1"]), id: podID, name: "p1")
        var body: [String: Any] = ["Image": "alpine", "Labels": ["x": "y"]]
        #expect(LibpodPodSchema.joinPod(pod, body: &body) == "pod-p1")
        #expect((body["Labels"] as? [String: Any])?[LibpodPodSchema.podLabel] as? String == podID)
        #expect((body["Labels"] as? [String: Any])?["x"] as? String == "y")
        #expect((body["HostConfig"] as? [String: Any])?["NetworkMode"] as? String == "pod-p1")
        // Two members sharing the pod hostname would collide in socktainer's DNS.
        #expect(body["Hostname"] == nil)
    }

    @Test("a pod member that picked its own network keeps it")
    func joinPodKeepsExplicitNetwork() throws {
        let pod = LibpodPodSchema.record(try LibpodPodSchema.createRequest(fromSpec: ["name": "p1"]), id: podID, name: "p1")
        var body: [String: Any] = ["Image": "alpine", "HostConfig": ["NetworkMode": "proj_default"]]
        #expect(LibpodPodSchema.joinPod(pod, body: &body) == nil)
        #expect((body["HostConfig"] as? [String: Any])?["NetworkMode"] as? String == "proj_default")
        #expect(body["Hostname"] == nil)
        #expect((body["Labels"] as? [String: Any])?[LibpodPodSchema.podLabel] as? String == podID)
    }

    @Test("list and inspect reports carry podman's field names and no infra container")
    func reports() throws {
        let pod = LibpodPodSchema.record(try LibpodPodSchema.createRequest(fromSpec: ["name": "p1"]), id: podID, name: "p1")
        let members = [LibpodPodMember(id: "c1", name: "a", state: "running", podID: podID)]

        let list = LibpodPodSchema.listReport(pod, members: members)
        #expect(list["Id"] as? String == podID)
        #expect(list["Name"] as? String == "p1")
        #expect(list["InfraId"] as? String == "")
        #expect(list["Status"] as? String == "Running")
        #expect(list["Networks"] as? [String] == ["pod-p1"])
        let containers = list["Containers"] as? [[String: Any]]
        #expect(containers?.first?["Names"] as? String == "a")
        #expect(containers?.first?["Status"] as? String == "running")

        let inspect = LibpodPodSchema.inspect(pod, members: members)
        #expect(inspect["State"] as? String == "Running")
        #expect(inspect["NumContainers"] as? Int == 1)
        #expect(inspect["CreateInfra"] as? Bool == false)
        #expect(inspect["InfraContainerID"] == nil)
        #expect((inspect["Containers"] as? [[String: Any]])?.first?["Id"] as? String == "c1")
        // Go's time.Time must be able to parse it.
        #expect((inspect["Created"] as? String)?.contains("T") == true)
    }

    @Test("pod list filters: name, id, label, status; unknown filters are rejected")
    func filters() throws {
        let request = try LibpodPodSchema.createRequest(fromSpec: ["name": "web1", "labels": ["tier": "front"]])
        let pod = LibpodPodSchema.record(request, id: podID, name: "web1")
        let running = [LibpodPodMember(id: "c", name: "c", state: "running", podID: podID)]
        #expect(try LibpodPodSchema.matches(pod, members: running, filters: ["name": ["web"]]))
        #expect(try !LibpodPodSchema.matches(pod, members: running, filters: ["name": ["db"]]))
        #expect(try LibpodPodSchema.matches(pod, members: running, filters: ["id": ["abab"]]))
        #expect(try LibpodPodSchema.matches(pod, members: running, filters: ["label": ["tier=front"]]))
        #expect(try LibpodPodSchema.matches(pod, members: running, filters: ["label": ["tier"]]))
        #expect(try !LibpodPodSchema.matches(pod, members: running, filters: ["label": ["tier=back"]]))
        #expect(try LibpodPodSchema.matches(pod, members: running, filters: ["status": ["running"]]))
        #expect(try !LibpodPodSchema.matches(pod, members: [], filters: ["status": ["running"]]))
        #expect(throws: LibpodPodSchema.PodFilterError.self) {
            _ = try LibpodPodSchema.matches(pod, members: running, filters: ["bogus": ["x"]])
        }
    }

    @Test("ps reports the pod of a pod member")
    func containerListPod() {
        let docker: [[String: Any]] = [
            ["Id": "c1", "Names": ["/a"], "State": "running", "Labels": [LibpodPodSchema.podLabel: podID]],
            ["Id": "c2", "Names": ["/b"], "State": "running", "Labels": [String: Any]()],
        ]
        let list = LibpodSchema.containerList(docker, podNames: [podID: "p1"]) as? [[String: Any]]
        #expect(list?[0]["Pod"] as? String == podID)
        #expect(list?[0]["PodName"] as? String == "p1")
        #expect(list?[1]["Pod"] as? String == "")
        #expect(list?[1]["PodName"] as? String == "")
    }

    @Test("container inspect reports the pod of a pod member")
    func containerInspectPod() {
        let inspect = LibpodSchema.containerInspect(["Name": "/a", "Config": ["Labels": [LibpodPodSchema.podLabel: podID]]]) as? [String: Any]
        #expect(inspect?["Pod"] as? String == podID)
    }
}
