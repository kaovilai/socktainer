import ContainerResource
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("QEMURuntime")
struct QEMURuntimeTests {
    private let arm64Host = Platform(arch: "arm64", os: "linux", variant: "v8")

    private func process(user: ProcessConfiguration.User = .id(uid: 0, gid: 0)) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "uname", arguments: ["-m"], environment: ["PATH=/bin"],
            workingDirectory: "/work", terminal: false, user: user)
    }

    private func config(_ process: ProcessConfiguration) -> ContainerConfiguration {
        let img = ImageDescription(
            reference: "h7/s390x:1",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: "sha256:abc", size: 0))
        return ContainerConfiguration(id: "c1", image: img, process: process)
    }

    @Test("only foreign linux architectures on an arm64 host get a handler")
    func handlerSelection() {
        #expect(QEMURuntime.handler(for: Platform(arch: "s390x", os: "linux"), host: arm64Host)?.qemuArch == "s390x")
        #expect(QEMURuntime.handler(for: Platform(arch: "ppc64le", os: "linux"), host: arm64Host)?.qemuArch == "ppc64le")
        #expect(QEMURuntime.handler(for: Platform(arch: "riscv64", os: "linux"), host: arm64Host)?.qemuArch == "riscv64")
        #expect(QEMURuntime.handler(for: Platform(arch: "arm64", os: "linux"), host: arm64Host) == nil)
        #expect(QEMURuntime.handler(for: Platform(arch: "amd64", os: "linux"), host: arm64Host) == nil)
        #expect(QEMURuntime.handler(for: Platform(arch: "s390x", os: "linux"), host: Platform(arch: "amd64", os: "linux")) == nil)
    }

    @Test("s390x registration matches the line proven on a VM kernel, with the fix-binary flag")
    func s390xRegistration() throws {
        let handler = try #require(QEMURuntime.handler(for: "s390x"))
        #expect(
            handler.registration(interpreterPath: "/.socktainer-qemu/qemu-s390x")
                == #":qemu-s390x:M::\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x16:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/.socktainer-qemu/qemu-s390x:F"#
        )
    }

    @Test("each magic and mask is 20 escaped bytes")
    func magicAndMaskLengths() throws {
        for arch in ["s390x", "ppc64le", "riscv64"] {
            let handler = try #require(QEMURuntime.handler(for: arch))
            // "\x7fELF" counts as 4 bytes in 7 characters.
            let magicBytes = handler.magic.replacingOccurrences(of: "ELF", with: #"\x00\x00\x00"#).components(separatedBy: #"\x"#).count - 1
            let maskBytes = handler.mask.components(separatedBy: #"\x"#).count - 1
            #expect(magicBytes == 20, "\(arch) magic")
            #expect(maskBytes == 20, "\(arch) mask")
        }
    }

    @Test("wrap runs busybox sh as root and passes the original command as $@")
    func wrapRoot() throws {
        let handler = try #require(QEMURuntime.handler(for: "s390x"))
        let wrapped = QEMURuntime.wrap(process(), handlers: [handler])
        #expect(wrapped.executable == "/.socktainer-qemu/busybox")
        #expect(Array(wrapped.arguments.prefix(2)) == ["sh", "-c"])
        #expect(Array(wrapped.arguments.suffix(3)) == ["socktainer-qemu", "uname", "-m"])
        #expect(wrapped.user == .id(uid: 0, gid: 0))
        #expect(wrapped.workingDirectory == "/work")
        #expect(wrapped.environment == ["PATH=/bin"])
        let script = wrapped.arguments[2]
        #expect(script.contains("mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc"))
        #expect(script.contains("> /proc/sys/fs/binfmt_misc/register"))
        #expect(script.hasSuffix("exec \"$@\""))
    }

    @Test("a non-root user is switched to with chpst after registration")
    func wrapNonRoot() throws {
        let handler = try #require(QEMURuntime.handler(for: "s390x"))
        let script = QEMURuntime.wrap(process(user: .raw(userString: "nobody")), handlers: [handler]).arguments[2]
        #expect(script.hasSuffix("exec /.socktainer-qemu/busybox chpst -u 'nobody' \"$@\""))
        #expect(QEMURuntime.chpstUser(.id(uid: 1000, gid: 100)) == "1000:100")
        #expect(QEMURuntime.chpstUser(.raw(userString: "root")) == nil)
        #expect(QEMURuntime.chpstUser(.raw(userString: "0:0")) == nil)
    }

    @Test("apply adds a read-only asset mount, CAP_SYS_ADMIN and the label")
    func applyConfiguration() throws {
        let handler = try #require(QEMURuntime.handler(for: "s390x"))
        var cfg = config(process())
        cfg.capDrop = ["CAP_SYS_ADMIN"]
        QEMURuntime.apply(to: &cfg, handlers: [handler], assetDirectory: URL(fileURLWithPath: "/tmp/q"))
        let mount = try #require(cfg.mounts.first { $0.destination == "/.socktainer-qemu" })
        #expect(mount.source == "/tmp/q")
        #expect(mount.options.contains("ro"))
        #expect(cfg.capAdd == ["CAP_SYS_ADMIN"])
        #expect(cfg.capDrop.isEmpty)
        #expect(cfg.labels[QEMURuntime.label] == "s390x")
        #expect(cfg.initProcess.executable == "/.socktainer-qemu/busybox")
    }

    @Test("apply keeps an existing ALL capability")
    func applyKeepsAll() throws {
        let handler = try #require(QEMURuntime.handler(for: "s390x"))
        var cfg = config(process())
        cfg.capAdd = ["ALL"]
        QEMURuntime.apply(to: &cfg, handlers: [handler], assetDirectory: URL(fileURLWithPath: "/tmp/q"))
        #expect(cfg.capAdd == ["ALL"])
    }

    @Test("best-effort wrapper for privileged containers registers every handler without exiting")
    func bestEffortAllHandlers() {
        let script = QEMURuntime.wrapperScript(handlers: QEMURuntime.allHandlers, user: .id(uid: 0, gid: 0), required: false)
        for arch in ["s390x", "ppc64le", "riscv64"] {
            #expect(script.contains(":qemu-\(arch):M::"))
        }
        #expect(!script.contains("exit 126"))
        var cfg = config(process())
        QEMURuntime.apply(to: &cfg, handlers: QEMURuntime.allHandlers, assetDirectory: URL(fileURLWithPath: "/tmp/q"), required: false)
        #expect(cfg.labels[QEMURuntime.label] == "s390x,ppc64le,riscv64")
    }

    @Test("only privileged arm64 linux containers emulate foreign platforms")
    func privilegedEmulation() throws {
        let arm64 = Platform(arch: "arm64", os: "linux", variant: "v8")
        let privileged = try JSONDecoder().decode(HostConfig.self, from: Data(#"{"Privileged":true}"#.utf8))
        let plain = try JSONDecoder().decode(HostConfig.self, from: Data(#"{}"#.utf8))
        #expect(ContainerCreateRoute.emulatesForeignPlatforms(hostConfig: privileged, platform: arm64, host: arm64Host))
        #expect(!ContainerCreateRoute.emulatesForeignPlatforms(hostConfig: plain, platform: arm64, host: arm64Host))
        #expect(!ContainerCreateRoute.emulatesForeignPlatforms(hostConfig: nil, platform: arm64, host: arm64Host))
        #expect(!ContainerCreateRoute.emulatesForeignPlatforms(hostConfig: privileged, platform: Platform(arch: "amd64", os: "linux"), host: arm64Host))
    }
}

@Suite("qemuFallbackPlatform")
struct QEMUFallbackPlatformTests {
    private let arm64 = Platform(arch: "arm64", os: "linux", variant: "v8")

    private func manifest(_ platform: Platform, attestation: Bool = false) -> Descriptor {
        Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: "sha256:\(platform.description.replacingOccurrences(of: "/", with: "-"))",
            size: 0,
            annotations: attestation ? ["vnd.docker.reference.type": "attestation-manifest"] : nil,
            platform: platform
        )
    }

    @Test("an s390x-only image runs as s390x, ignoring attestation manifests")
    func s390xOnly() {
        let s390x = Platform(arch: "s390x", os: "linux")
        let unknown = Platform(arch: "unknown", os: "unknown")
        #expect(qemuFallbackPlatform(for: arm64, imageManifests: [manifest(s390x), manifest(unknown, attestation: true)]) == s390x)
    }

    @Test("amd64 present, several foreign platforms, or nothing cached: no QEMU fallback")
    func noFallback() {
        let s390x = Platform(arch: "s390x", os: "linux")
        let amd64 = Platform(arch: "amd64", os: "linux")
        let ppc = Platform(arch: "ppc64le", os: "linux")
        #expect(qemuFallbackPlatform(for: arm64, imageManifests: [manifest(s390x), manifest(amd64)]) == nil)
        #expect(qemuFallbackPlatform(for: arm64, imageManifests: [manifest(s390x), manifest(ppc)]) == nil)
        #expect(qemuFallbackPlatform(for: arm64, imageManifests: nil) == nil)
        #expect(qemuFallbackPlatform(for: arm64, imageManifests: [manifest(Platform(arch: "mips64", os: "linux"))]) == nil)
    }
}
