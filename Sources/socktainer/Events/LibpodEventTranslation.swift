/// Rewrites Docker-shaped events into podman's event vocabulary for `/libpod/events`.
///
/// The podman client decodes every event with `entities.ConvertToLibpodEvent`, which
/// fails — and `podman events` reports "converting event from server" — when the
/// action is not a podman `events.Status` or the type is not a podman `events.Type`.
/// Docker-only actions are renamed where podman has an equivalent (`die` → `died`,
/// `destroy`/`delete` → `remove`, ...) and dropped otherwise, mirroring the inverse
/// of podman's own compat conversion in `pkg/api/handlers/compat/events.go`.
enum LibpodEventTranslation {
    /// podman `libpod/events/config.go` `Status` values.
    static let podmanStatuses: Set<String> = [
        "attach", "auto-update", "build", "checkpoint", "cleanup", "commit", "copy", "create",
        "exec", "exec_died", "died", "export", "health_status", "history", "import", "init", "kill",
        "loadfromarchive", "mount", "connect", "disconnect", "pause", "prune", "pull", "pull-error",
        "push", "refresh", "remove", "rename", "renumber", "restart", "restore", "log-rotation",
        "save", "start", "stop", "sync", "tag", "unmount", "unpause", "untag", "update",
    ]

    /// podman `libpod/events/config.go` `Type` values.
    static let podmanTypes: Set<String> = [
        "container", "image", "artifact", "network", "pod", "system", "volume", "machine", "secret",
    ]

    static func translate(_ event: DockerEvent) -> DockerEvent? {
        guard podmanTypes.contains(event.Type) else { return nil }

        var attributes = event.Actor.Attributes
        var healthStatus: String? = nil
        let action: String

        switch (event.Type, event.Action) {
        case ("container", "die"):
            action = "died"
            if let code = attributes["exitCode"] { attributes["containerExitCode"] = code }
        case ("container", let a) where a.hasPrefix("exec_start"):
            action = "exec"
        case ("container", "exec_die"):
            action = "exec_died"
            if let code = attributes["exitCode"] { attributes["containerExitCode"] = code }
        case ("container", let a) where a.hasPrefix("health_status"):
            action = "health_status"
            if let colon = a.firstIndex(of: ":") {
                healthStatus = a[a.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        case (_, "destroy"), ("image", "delete"):
            action = "remove"
        case ("image", "load"):
            action = "loadfromarchive"
        case (_, let a) where podmanStatuses.contains(a):
            action = a
        default:
            // exec_create, exec_detach, resize, detach, archive-path, extract-to-dir, oom, ...
            return nil
        }

        // podman volume events carry the volume name in `Name`, not in the ID.
        if event.Type == "volume", attributes["name"] == nil {
            attributes["name"] = event.Actor.ID
        }

        // moby's network events are about the network (Actor.ID = network id, `container`
        // and `name` attributes); podman's are about the container (libpod
        // `newNetworkEvent`: ID = container id, `network` = network name).
        var actorID = event.Actor.ID
        if event.Type == "network", let container = attributes["container"] {
            actorID = container
            attributes = ["network": attributes["name"] ?? event.Actor.ID]
        }

        var translated = DockerEvent(
            status: action,
            id: event.id,
            from: event.from,
            Type: event.Type,
            Action: action,
            Actor: DockerActor(ID: actorID, Attributes: attributes),
            scope: event.scope,
            time: event.time,
            timeNano: event.timeNano
        )
        translated.HealthStatus = healthStatus
        return translated
    }
}
