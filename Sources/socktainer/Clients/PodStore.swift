import Foundation
import Logging

/// A podman pod as socktainer models it: a named group of containers.
///
/// Apple Container runs every container in its own VM, so members cannot share a
/// network namespace, `localhost`, IPC or UTS the way podman's infra container lets
/// them. What a pod can offer here is grouping (members are started, stopped, killed
/// and removed together) and, when the pod would share its network, a dedicated
/// network on which members reach each other by name.
struct PodRecord: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let created: Date
    let labels: [String: String]
    let hostname: String
    /// The Apple network members join when they ask for no network of their own; nil when
    /// the pod does not share its network (`--share` without `net`, or `--infra=false`).
    let network: String?
    /// Whether socktainer created `network` for this pod (and removes it with the pod), as
    /// opposed to an existing network the pod was told to use.
    let ownsNetwork: Bool
    let sharedNamespaces: [String]
}

enum PodStoreError: Error, CustomStringConvertible {
    case nameInUse(String)
    case invalidName(String)

    var description: String {
        switch self {
        case .nameInUse(let name):
            return "pod \(name) already exists: pod already exists"
        case .invalidName(let name):
            return "invalid pod name \(name): names must match [a-zA-Z0-9][a-zA-Z0-9_.-]*"
        }
    }
}

/// Pods have no counterpart in Apple Container, so socktainer keeps them itself,
/// persisted next to its other per-container records so they survive a daemon
/// restart. Membership is not stored here: it is a label on each member container,
/// which disappears with the container.
actor PodStore {
    static let shared = PodStore()

    private var pods: [String: PodRecord] = [:]
    private var fileURL: URL?
    private let log = Logger(label: "socktainer.pods")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL { pods = Self.load(from: fileURL, log: log) }
    }

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent("socktainer-pods.json")
        fileURL = url
        pods = Self.load(from: url, log: log)
    }

    private static func load(from url: URL, log: Logger) -> [String: PodRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([String: PodRecord].self, from: Data(contentsOf: url))
        } catch {
            log.error("could not load pods from \(url.path) — pods created by earlier runs are not listed: \(error)")
            return [:]
        }
    }

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    /// Records a new pod. `make` receives the generated ID and the name (the ID's short
    /// form when none was requested) so the caller can derive per-pod resources from them.
    func create(name requested: String, make: @Sendable (_ id: String, _ name: String) -> PodRecord) throws -> PodRecord {
        var id = Self.generateID()
        while pods[id] != nil { id = Self.generateID() }
        let name = requested.isEmpty ? String(id.prefix(12)) : requested
        guard Self.isValidName(name) else { throw PodStoreError.invalidName(name) }
        guard !pods.values.contains(where: { $0.name == name }) else { throw PodStoreError.nameInUse(name) }
        let record = make(id, name)
        pods[record.id] = record
        try persist()
        return record
    }

    /// The pod with this full ID, name, or unambiguous ID prefix — podman's lookup order.
    func resolve(_ reference: String) -> PodRecord? {
        guard !reference.isEmpty else { return nil }
        if let exact = pods[reference] { return exact }
        if let named = pods.values.first(where: { $0.name == reference }) { return named }
        let matches = pods.values.filter { $0.id.hasPrefix(reference) }
        return matches.count == 1 ? matches.first : nil
    }

    func all() -> [PodRecord] {
        pods.values.sorted { $0.created < $1.created }
    }

    func remove(id: String) throws {
        guard pods.removeValue(forKey: id) != nil else { return }
        try persist()
    }

    private func persist() throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pods).write(to: fileURL, options: .atomic)
    }

    private static func generateID() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
