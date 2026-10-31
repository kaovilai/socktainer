import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging

/// Runs Linux images for architectures Apple Silicon cannot execute natively or through
/// Rosetta (s390x, ppc64le, riscv64) under QEMU user-mode emulation.
///
/// Apple creates such a container without complaint, but its VM kernel has no binfmt_misc
/// handler, so the first exec fails with ENOEXEC. Every container is its own VM, so the handler
/// has to be registered inside that VM before the user process runs. Apple's runtime only
/// accepts an exec once the init process has started, so the init process itself does it: a
/// static arm64 busybox (shared read-only from the host) mounts binfmt_misc, registers a static
/// arm64 qemu-user binary with the F (fix-binary) flag, and then execs the original command.
/// The fix-binary flag opens the interpreter at registration time, so later `docker exec`s in
/// the same container are emulated too.
///
/// Costs: the container gets CAP_SYS_ADMIN (needed to mount binfmt_misc and register), which
/// the user process keeps when it runs as root; the VM is the isolation boundary either way.
enum QEMURuntime {
    /// Where the host asset directory is mounted inside the container.
    static let mountPoint = "/.socktainer-qemu"
    /// `busybox:musl` ships a statically linked busybox; the default glibc variant is dynamic.
    static let busyboxImage = "docker.io/library/busybox:musl"
    static let busyboxName = "busybox"
    /// The capability the wrapper needs to mount binfmt_misc and write its register file.
    static let requiredCapability = "CAP_SYS_ADMIN"
    /// Recorded on the container so the original command can be recovered from the wrapper.
    static let label = "io.github.socktainer.qemu"

    struct Handler: Equatable {
        /// qemu's name for the architecture (`qemu-<name>`, binfmt entry name).
        let qemuArch: String
        /// ELF header magic and mask in binfmt_misc's `\xNN` notation (from qemu-binfmt-conf.sh).
        let magic: String
        let mask: String

        var interpreterName: String { "qemu-\(qemuArch)" }

        /// The line written to /proc/sys/fs/binfmt_misc/register. The kernel decodes the
        /// `\xNN` escapes itself, so this stays plain ASCII.
        func registration(interpreterPath: String) -> String {
            ":\(interpreterName):M::\(magic):\(mask):\(interpreterPath):F"
        }
    }

    /// The QEMU handler for an OCI architecture, or nil when the host runs it natively
    /// (arm64) or through Rosetta (amd64), or when no handler is known.
    static func handler(for architecture: String) -> Handler? {
        switch architecture.lowercased() {
        case "s390x":
            return Handler(
                qemuArch: "s390x",
                magic: #"\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x16"#,
                mask: #"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff"#)
        case "ppc64le":
            return Handler(
                qemuArch: "ppc64le",
                magic: #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x15\x00"#,
                mask: #"\xff\xff\xff\xff\xff\xff\xff\xfc\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\x00"#)
        case "riscv64":
            return Handler(
                qemuArch: "riscv64",
                magic: #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00"#,
                mask: #"\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#)
        default:
            return nil
        }
    }

    /// Whether `platform` needs QEMU on this host: a known foreign architecture on an arm64 host.
    static func handler(for platform: Platform, host: Platform = .current) -> Handler? {
        guard host.architecture == "arm64", platform.os == "linux" else { return nil }
        return handler(for: platform.architecture)
    }

    /// The shell script the wrapper runs with `busybox sh -c`. `$@` is the original command.
    /// A non-root user is switched to with busybox `chpst` after registration.
    static func wrapperScript(handler: Handler, user: ProcessConfiguration.User) -> String {
        let busybox = "\(mountPoint)/\(busyboxName)"
        let entry = "/proc/sys/fs/binfmt_misc/\(handler.interpreterName)"
        let registration = handler.registration(interpreterPath: "\(mountPoint)/\(handler.interpreterName)")
        var lines = [
            "\(busybox) mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null",
            "[ -e \(entry) ] || echo '\(registration)' > /proc/sys/fs/binfmt_misc/register || { echo 'socktainer: cannot register \(handler.interpreterName) with binfmt_misc' >&2; exit 126; }",
        ]
        if let chpstUser = chpstUser(user) {
            lines.append("exec \(busybox) chpst -u '\(chpstUser)' \"$@\"")
        } else {
            lines.append("exec \"$@\"")
        }
        return lines.joined(separator: "\n")
    }

    /// The `chpst -u` argument for a non-root user, or nil for root.
    static func chpstUser(_ user: ProcessConfiguration.User) -> String? {
        switch user {
        case .id(let uid, let gid):
            return uid == 0 && gid == 0 ? nil : "\(uid):\(gid)"
        case .raw(let userString):
            let trimmed = userString.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "root" || trimmed == "0" || trimmed == "root:root" || trimmed == "0:0" {
                return nil
            }
            // chpst takes USER[:GROUP]; a single quote cannot be escaped inside '...'.
            return trimmed.contains("'") ? nil : trimmed
        }
    }

    /// Wraps `process` so the container's init registers QEMU before running the original command.
    static func wrap(_ process: ProcessConfiguration, handler: Handler) -> ProcessConfiguration {
        var wrapped = process
        wrapped.executable = "\(mountPoint)/\(busyboxName)"
        wrapped.arguments = ["sh", "-c", wrapperScript(handler: handler, user: process.user), "socktainer-qemu", process.executable] + process.arguments
        wrapped.user = .id(uid: 0, gid: 0)
        return wrapped
    }

    /// Applies emulation to a container configuration: wrapped init, read-only asset mount,
    /// CAP_SYS_ADMIN, and a label naming the emulated architecture.
    static func apply(to config: inout ContainerConfiguration, handler: Handler, assetDirectory: URL) {
        config.initProcess = wrap(config.initProcess, handler: handler)
        config.mounts.append(.virtiofs(source: assetDirectory.path, destination: mountPoint, options: ["ro"]))
        if !config.capAdd.contains(where: { $0.uppercased() == "ALL" || $0.uppercased() == requiredCapability }) {
            config.capAdd.append(requiredCapability)
        }
        config.capDrop.removeAll { $0.uppercased() == requiredCapability }
        config.labels[label] = handler.qemuArch
    }

    // MARK: - Host assets

    static var assetDirectory: URL {
        AppleContainerTimestampResolver.appSupportURL.appendingPathComponent("socktainer-qemu")
    }

    /// Makes sure the static busybox and `qemu-<arch>` exist in `assetDirectory`, extracting
    /// them from `busybox:musl` and the BuildKit builder image (which ships static
    /// `buildkit-qemu-*` binaries) on first use.
    static func ensureAssets(handler: Handler, containerSystemConfig: ContainerSystemConfig, logger: Logger?) async throws -> URL {
        let dir = assetDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let busybox = dir.appendingPathComponent(busyboxName)
        if !FileManager.default.isExecutableFile(atPath: busybox.path) {
            logger?.info("[qemu] extracting static busybox from \(busyboxImage)")
            try await extract(member: "bin/busybox", from: busyboxImage, to: busybox, containerSystemConfig: containerSystemConfig)
        }
        let qemu = dir.appendingPathComponent(handler.interpreterName)
        if !FileManager.default.isExecutableFile(atPath: qemu.path) {
            let builderImage = containerSystemConfig.build.image
            logger?.info("[qemu] extracting buildkit-qemu-\(handler.qemuArch) from \(builderImage)")
            try await extract(
                member: "usr/bin/buildkit-qemu-\(handler.qemuArch)", from: builderImage, to: qemu, containerSystemConfig: containerSystemConfig)
        }
        return dir
    }

    /// Copies one file out of an arm64 image's layers (topmost layer first) into `destination`.
    private static func extract(member: String, from reference: String, to destination: URL, containerSystemConfig: ContainerSystemConfig) async throws {
        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let image = try await ClientImage.fetch(
            reference: reference,
            platform: platform,
            scheme: RegistryScheme.scheme(forReference: reference, internalDnsDomain: containerSystemConfig.dns.domain),
            containerSystemConfig: containerSystemConfig
        )
        let manifest = try await image.manifest(for: platform)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("socktainer-qemu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for layer in manifest.layers.reversed() {
            guard let content = try await RemoteContentStoreClient().get(digest: layer.digest) else { continue }
            let extracted = scratch.appendingPathComponent(member)
            // busybox images store bin/busybox as a hard link to another applet, which tar
            // cannot extract alone; fall back to the whole layer.
            try untar(content.path, into: scratch, members: [member])
            if !FileManager.default.fileExists(atPath: extracted.path) {
                try untar(content.path, into: scratch, members: [])
            }
            guard FileManager.default.fileExists(atPath: extracted.path) else { continue }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extracted.path)
            // Rename into place so a concurrent create never sees a partial binary.
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
            try FileManager.default.moveItem(at: extracted, to: staged)
            if rename(staged.path, destination.path) != 0 {
                try? FileManager.default.removeItem(at: staged)
                throw ContainerizationError(.internalError, message: "cannot install \(destination.path): errno \(errno)")
            }
            return
        }
        throw ContainerizationError(.notFound, message: "\(member) not found in \(reference)")
    }

    private static func untar(_ archive: URL, into directory: URL, members: [String]) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", directory.path] + members
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
    }
}
