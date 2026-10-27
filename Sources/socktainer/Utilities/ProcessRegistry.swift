import ContainerAPIClient
import ContainerizationOS

/// Shared registry of running ClientProcess instances keyed by container or exec ID.
/// Allows the resize routes to forward terminal size changes to the active process
/// without threading the process reference through the HTTP layer.
actor ProcessRegistry {
    static let shared = ProcessRegistry()

    private var processes: [String: any ClientProcess] = [:]
    // Sizes requested before the process existed: podman resizes the terminal of
    // `run -it` as soon as it attaches, before it starts the container.
    private var pendingSizes: [String: Terminal.Size] = [:]

    func set(id: String, process: any ClientProcess) {
        processes[id] = process
        if let size = pendingSizes.removeValue(forKey: id) {
            Task { try? await process.resize(size) }
        }
    }

    func get(id: String) -> (any ClientProcess)? {
        processes[id]
    }

    func remove(id: String) {
        processes.removeValue(forKey: id)
    }

    /// Remembers `size` for the process `id` will have once it starts.
    func setPendingSize(id: String, size: Terminal.Size) {
        pendingSizes[id] = size
    }
}
