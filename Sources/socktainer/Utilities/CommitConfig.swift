import Foundation

/// Builds the image config `docker commit` / `podman commit` writes for a container.
///
/// moby starts from the container's own config (itself the base image config merged with
/// the run options), lets a non-empty field of the request body's config override it, then
/// applies the `changes` Dockerfile instructions. Apple Container keeps only the resolved
/// process (executable + arguments, env, working directory, user) and labels, so this
/// starts from the base image's raw config — keeping fields Apple drops, like ExposedPorts,
/// Volumes, Healthcheck and StopSignal — and overlays what the container actually runs.
enum CommitConfigComposer {
    struct Container {
        var executable: String
        var arguments: [String]
        var env: [String]
        var workingDir: String
        var user: String?
        var labels: [String: String]
    }

    /// Labels socktainer stores on containers for its own bookkeeping; they describe the
    /// container, not the image, and must not leak into a committed image.
    private static let internalLabelPrefixes = ["socktainer.", "io.github.socktainer."]

    static func compose(
        base: [String: Any],
        container: Container,
        overrides: [String: Any]?,
        changes: [String]
    ) throws -> [String: Any] {
        var config = base

        let (entrypoint, cmd) = splitProcess(
            executable: container.executable,
            arguments: container.arguments,
            imageEntrypoint: base["Entrypoint"] as? [String] ?? [],
            imageCmd: base["Cmd"] as? [String] ?? []
        )
        config["Entrypoint"] = entrypoint
        config["Cmd"] = cmd
        if !container.env.isEmpty { config["Env"] = container.env }
        if !container.workingDir.isEmpty { config["WorkingDir"] = container.workingDir }
        if let user = container.user, !user.isEmpty { config["User"] = user }

        var labels = base["Labels"] as? [String: String] ?? [:]
        for (key, value) in container.labels where !internalLabelPrefixes.contains(where: key.hasPrefix) {
            labels[key] = value
        }
        config["Labels"] = labels.isEmpty ? nil : labels

        for (key, value) in overrides ?? [:] where isSet(value) {
            config[key] = value
        }

        guard !changes.isEmpty else { return compacted(config) }
        var synthesized = SynthesizedImageConfig(dictionary: config)
        try DockerfileChangeApplier.apply(changes, to: &synthesized)
        for key in SynthesizedImageConfig.keys {
            config[key] = nil
        }
        return compacted(config.merging(synthesized.toDict()) { _, new in new })
    }

    /// Recovers the Entrypoint/Cmd split Apple flattens into one argv. The image's own
    /// split is kept when the container runs it unchanged or only replaced the command;
    /// otherwise the entrypoint was overridden (or the image had none).
    static func splitProcess(
        executable: String,
        arguments: [String],
        imageEntrypoint: [String],
        imageCmd: [String]
    ) -> (entrypoint: [String]?, cmd: [String]?) {
        let argv = [executable] + arguments
        if argv == imageEntrypoint + imageCmd {
            return (imageEntrypoint.isEmpty ? nil : imageEntrypoint, imageCmd.isEmpty ? nil : imageCmd)
        }
        if imageEntrypoint.isEmpty {
            return (nil, argv)
        }
        if argv.starts(with: imageEntrypoint) {
            let cmd = Array(argv.dropFirst(imageEntrypoint.count))
            return (imageEntrypoint, cmd.isEmpty ? nil : cmd)
        }
        return ([executable], arguments.isEmpty ? nil : arguments)
    }

    /// A body field the client left empty (null, "", [], {}) does not override.
    private static func isSet(_ value: Any) -> Bool {
        switch value {
        case is NSNull: return false
        case let string as String: return !string.isEmpty
        case let array as [Any]: return !array.isEmpty
        case let object as [String: Any]: return !object.isEmpty
        default: return true
        }
    }

    private static func compacted(_ config: [String: Any]) -> [String: Any] {
        config.filter { !($0.value is NSNull) }
    }
}

extension SynthesizedImageConfig {
    /// The image-config keys `toDict()` owns.
    static let keys = ["User", "ExposedPorts", "Env", "Entrypoint", "Cmd", "Volumes", "WorkingDir", "Labels"]

    init(dictionary: [String: Any]) {
        self.init()
        user = dictionary["User"] as? String
        exposedPorts = Set((dictionary["ExposedPorts"] as? [String: Any])?.keys.map { $0 } ?? [])
        env = dictionary["Env"] as? [String] ?? []
        entrypoint = dictionary["Entrypoint"] as? [String]
        cmd = dictionary["Cmd"] as? [String]
        volumes = Set((dictionary["Volumes"] as? [String: Any])?.keys.map { $0 } ?? [])
        workingDir = dictionary["WorkingDir"] as? String
        labels = dictionary["Labels"] as? [String: String] ?? [:]
    }
}
