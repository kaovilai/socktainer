import Foundation

/// A container that belongs to a pod, as the pod routes see it.
struct LibpodPodMember: Sendable, Equatable {
    let id: String
    let name: String
    /// Docker's lower-case state: `created`, `running`, `paused`, `exited`, ...
    let state: String
    let podID: String
}

/// Pure translations between socktainer's pod records and podman's pod wire shapes
/// (`types.ListPodsReport`, `define.InspectPodData`, `specgen.PodSpecGenerator`).
enum LibpodPodSchema {
    /// Container label carrying the ID of the pod the container belongs to.
    static let podLabel = "io.socktainer.pod"

    /// What podman shares when `--share` is not given.
    static let defaultSharedNamespaces = ["ipc", "net", "uts"]

    enum SpecError: Error, CustomStringConvertible {
        case portsNeedInfra

        var description: String {
            switch self {
            case .portsNeedInfra:
                return
                    "publishing ports on a pod needs an infra container, which socktainer does not run (each container is its own VM): publish the ports on the member containers instead"
            }
        }
    }

    // MARK: Create

    /// What `podman pod create` asked for, before the pod has an ID.
    struct CreateRequest: Sendable, Equatable {
        let name: String
        let labels: [String: String]
        let hostname: String
        /// A network named with `--network`; the pod then uses it instead of its own.
        let network: String?
        let sharedNamespaces: [String]
        /// `--network host|none|ns:...`: no pod network.
        let isolatedNetwork: Bool
    }

    /// Reads podman's `PodSpecGenerator`. Pod-level settings that only an infra container
    /// could carry are refused rather than silently dropped.
    static func createRequest(fromSpec spec: [String: Any]) throws -> CreateRequest {
        if let ports = spec["portmappings"] as? [Any], !ports.isEmpty {
            throw SpecError.portsNeedInfra
        }
        let noInfra = spec["no_infra"] as? Bool ?? false
        let requestedShares = (spec["shared_namespaces"] as? [String]).map { shares in
            shares.flatMap { $0.split(separator: ",").map(String.init) }.filter { !$0.isEmpty }
        }
        let nsmode = (spec["netns"] as? [String: Any])?["nsmode"] as? String ?? ""
        return CreateRequest(
            name: spec["name"] as? String ?? "",
            labels: spec["labels"] as? [String: String] ?? [:],
            hostname: spec["hostname"] as? String ?? "",
            network: (spec["Networks"] as? [String: Any])?.keys.sorted().first,
            // Without an infra container podman shares nothing.
            sharedNamespaces: noInfra ? [] : (requestedShares ?? defaultSharedNamespaces),
            isolatedNetwork: ["host", "none", "ns"].contains(nsmode)
        )
    }

    static func record(_ request: CreateRequest, id: String, name: String, now: Date = Date()) -> PodRecord {
        var network = request.network
        var ownsNetwork = false
        if network == nil, request.sharedNamespaces.contains("net"), !request.isolatedNetwork {
            network = networkName(podName: name, podID: id)
            ownsNetwork = true
        }
        return PodRecord(
            id: id, name: name, created: now, labels: request.labels, hostname: request.hostname, network: network,
            ownsNetwork: ownsNetwork, sharedNamespaces: request.sharedNamespaces)
    }

    /// The Apple network a pod's members share. Apple network names are lower-case and at
    /// most 63 characters; pod names that cannot be mapped fall back to the pod ID.
    static func networkName(podName: String, podID: String) -> String {
        let candidate = "pod-" + podName.lowercased().replacingOccurrences(of: "_", with: "-")
        let valid = candidate.range(of: #"^[a-z0-9](?:[a-z0-9._-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
        return valid ? candidate : "pod-" + podID.prefix(12)
    }

    // MARK: Joining a pod

    /// Adds `pod` membership to a Docker create body. Returns the network the
    /// container was placed on, which the caller must make sure exists. The pod hostname is not
    /// given to members: they do not share a UTS namespace, and socktainer's DNS registers each
    /// container's hostname, so two members with one hostname would collide.
    static func joinPod(_ pod: PodRecord, body: inout [String: Any]) -> String? {
        var labels = body["Labels"] as? [String: Any] ?? [:]
        labels[podLabel] = pod.id
        body["Labels"] = labels

        // Members that chose a network keep it (podman-compose attaches its project network);
        // the rest join the pod's, which is the nearest thing to podman's shared netns.
        guard let network = pod.network else { return nil }
        var host = body["HostConfig"] as? [String: Any] ?? [:]
        let mode = host["NetworkMode"] as? String ?? ""
        guard mode.isEmpty || mode == "default" || mode == "bridge" else { return nil }
        host["NetworkMode"] = network
        body["HostConfig"] = host
        return network
    }

    // MARK: Status

    /// podman's `createPodStatusResults`, over Docker container states.
    static func status(memberStates: [String]) -> String {
        guard !memberStates.isEmpty else { return "Created" }
        var running = 0
        var paused = 0
        var stopped = 0
        var created = 0
        var errored = 0
        for state in memberStates {
            switch state.lowercased() {
            case "running": running += 1
            case "paused": paused += 1
            case "exited", "stopped", "dead": stopped += 1
            case "created", "configured": created += 1
            default: errored += 1
            }
        }
        let count = memberStates.count
        switch true {
        case running == count: return "Running"
        case running > 0: return "Degraded"
        case paused == count: return "Paused"
        case stopped == count: return "Exited"
        case stopped > 0: return "Stopped"
        case errored > 0: return "Error"
        default: return "Created"
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: Reports

    /// `types.ListPodsReport`. There is no infra container, so `InfraId` is empty.
    static func listReport(_ pod: PodRecord, members: [LibpodPodMember]) -> [String: Any] {
        [
            "Cgroup": "",
            "Containers": members.map { ["Id": $0.id, "Names": $0.name, "Status": $0.state, "RestartCount": 0] as [String: Any] },
            "Created": timestamp(pod.created),
            "Id": pod.id,
            "InfraId": "",
            "Name": pod.name,
            "Namespace": "",
            "Networks": pod.network.map { [$0] } ?? [],
            "Status": status(memberStates: members.map(\.state)),
            "Labels": pod.labels,
        ]
    }

    /// `define.InspectPodData`. `SharedNamespaces` is empty because members never share a
    /// kernel namespace here; the pod network only stands in for a shared netns.
    static func inspect(_ pod: PodRecord, members: [LibpodPodMember]) -> [String: Any] {
        var data: [String: Any] = [
            "Id": pod.id,
            "Name": pod.name,
            "Created": timestamp(pod.created),
            "ExitPolicy": "continue",
            "State": status(memberStates: members.map(\.state)),
            "Hostname": pod.hostname,
            "CreateCgroup": false,
            "CreateInfra": false,
            "NumContainers": members.count,
            "Containers": members.map { ["Id": $0.id, "Name": $0.name, "State": $0.state] },
            "LockNumber": 0,
        ]
        if !pod.labels.isEmpty { data["Labels"] = pod.labels }
        return data
    }

    // MARK: Filters

    /// podman's pod list filters this socktainer can answer: `id`, `name`, `label`, `status`,
    /// `network`. Values of one filter are OR-ed, different filters AND-ed. Unknown filters are
    /// rejected, as podman does.
    static func matches(_ pod: PodRecord, members: [LibpodPodMember], filters: [String: [String]]) throws -> Bool {
        for (key, values) in filters where !values.isEmpty {
            let ok: Bool
            switch key {
            case "id":
                ok = values.contains { pod.id.hasPrefix($0) }
            case "name":
                ok = values.contains { value in
                    pod.name == value || pod.name.range(of: value, options: .regularExpression) != nil
                }
            case "label":
                ok = values.contains { value in
                    let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let key = parts.first, let present = pod.labels[key] else { return false }
                    return parts.count == 1 || present == parts[1]
                }
            case "status":
                let current = status(memberStates: members.map(\.state)).lowercased()
                ok = values.contains { $0.lowercased() == current }
            case "network":
                ok = values.contains { $0 == pod.network }
            default:
                throw PodFilterError.unsupported(key)
            }
            if !ok { return false }
        }
        return true
    }

    enum PodFilterError: Error, CustomStringConvertible {
        case unsupported(String)
        var description: String {
            switch self {
            case .unsupported(let key): return "\(key) is an invalid filter"
            }
        }
    }
}
