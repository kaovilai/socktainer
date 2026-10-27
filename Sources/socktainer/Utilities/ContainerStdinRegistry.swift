import ContainerAPIClient
import ContainerResource
import Foundation

/// Write ends of the stdin pipes of running containers (and exec sessions) that no client is
/// attached to: a container started detached with `OpenStdin`, or one whose attached client
/// typed the detach keys. A later attach writes into the same pipe, so the process keeps one
/// stdin across attaches, as in Docker. The registry owns each write end and closes it when
/// the process exits.
actor ContainerStdinRegistry {
    static let shared = ContainerStdinRegistry()

    /// Marks a container created with `OpenStdin` (`-i`); Apple Container has no such setting.
    static let openStdinLabel = "socktainer.open-stdin"

    static func opensStdin(_ container: ContainerSnapshot) -> Bool {
        container.configuration.labels[openStdinLabel] == "true"
    }

    private var writers: [String: FileHandle] = [:]

    /// Keeps `writer` for `id`, closing any write end kept before it.
    func park(id: String, writer: FileHandle) {
        if let previous = writers.updateValue(writer, forKey: id), previous !== writer {
            try? previous.close()
        }
    }

    /// A duplicate of the kept write end for an attaching client. Closing the duplicate when the
    /// client leaves does not close the process's stdin. The caller closes it.
    func duplicateWriter(id: String) -> FileHandle? {
        guard let writer = writers[id] else { return nil }
        let fd = dup(writer.fileDescriptor)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    func hasWriter(id: String) -> Bool {
        writers[id] != nil
    }

    /// Closes and forgets the write end kept for `id` (the process exited).
    func close(id: String) {
        try? writers.removeValue(forKey: id)?.close()
    }
}
