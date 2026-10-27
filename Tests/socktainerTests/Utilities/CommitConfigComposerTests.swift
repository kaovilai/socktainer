import Foundation
import Testing

@testable import socktainer

@Suite("CommitConfigComposer")
struct CommitConfigComposerTests {
    private func container(
        _ argv: [String], env: [String] = [], workingDir: String = "/", user: String? = nil, labels: [String: String] = [:]
    ) -> CommitConfigComposer.Container {
        CommitConfigComposer.Container(
            executable: argv[0], arguments: Array(argv.dropFirst()), env: env, workingDir: workingDir, user: user, labels: labels)
    }

    @Test("a container running its image's default command keeps the image's Entrypoint/Cmd split")
    func keepsImageSplit() {
        let split = CommitConfigComposer.splitProcess(
            executable: "/docker-entrypoint.sh", arguments: ["nginx", "-g", "daemon off;"],
            imageEntrypoint: ["/docker-entrypoint.sh"], imageCmd: ["nginx", "-g", "daemon off;"])
        #expect(split.entrypoint == ["/docker-entrypoint.sh"])
        #expect(split.cmd == ["nginx", "-g", "daemon off;"])
    }

    @Test("a replaced command on an image without an entrypoint becomes Cmd only")
    func replacedCommandIsCmd() {
        let split = CommitConfigComposer.splitProcess(
            executable: "sleep", arguments: ["300"], imageEntrypoint: [], imageCmd: ["/bin/sh"])
        #expect(split.entrypoint == nil)
        #expect(split.cmd == ["sleep", "300"])
    }

    @Test("a replaced command behind the image's entrypoint keeps the entrypoint")
    func replacedCommandKeepsEntrypoint() {
        let split = CommitConfigComposer.splitProcess(
            executable: "/entry.sh", arguments: ["serve"], imageEntrypoint: ["/entry.sh"], imageCmd: ["run"])
        #expect(split.entrypoint == ["/entry.sh"])
        #expect(split.cmd == ["serve"])
    }

    @Test("an overridden entrypoint becomes the new entrypoint")
    func overriddenEntrypoint() {
        let split = CommitConfigComposer.splitProcess(
            executable: "/bin/bash", arguments: ["-c", "true"], imageEntrypoint: ["/entry.sh"], imageCmd: ["run"])
        #expect(split.entrypoint == ["/bin/bash"])
        #expect(split.cmd == ["-c", "true"])
    }

    @Test("base fields Apple does not model survive; container env, workdir and labels overlay them")
    func overlaysContainerOnBase() throws {
        let base: [String: Any] = [
            "Cmd": ["/bin/sh"],
            "Env": ["PATH=/usr/bin"],
            "ExposedPorts": ["80/tcp": [String: Any]()],
            "StopSignal": "SIGQUIT",
            "Labels": ["from": "image"],
        ]
        let composed = try CommitConfigComposer.compose(
            base: base,
            container: container(
                ["/bin/sh"], env: ["PATH=/usr/bin", "EXTRA=1"], workingDir: "/srv",
                labels: ["from": "container", "socktainer.port-bindings": "{}", "io.github.socktainer.id-seed": "x"]),
            overrides: nil,
            changes: []
        )
        #expect(composed["Cmd"] as? [String] == ["/bin/sh"])
        #expect(composed["Entrypoint"] == nil)
        #expect(composed["Env"] as? [String] == ["PATH=/usr/bin", "EXTRA=1"])
        #expect(composed["WorkingDir"] as? String == "/srv")
        #expect(composed["StopSignal"] as? String == "SIGQUIT")
        #expect((composed["ExposedPorts"] as? [String: Any])?.keys.sorted() == ["80/tcp"])
        #expect(composed["Labels"] as? [String: String] == ["from": "container"])
    }

    @Test("a set body field overrides; an empty one does not")
    func bodyOverrides() throws {
        let composed = try CommitConfigComposer.compose(
            base: ["Cmd": ["/bin/sh"]],
            container: container(["/bin/sh"], env: ["A=1"]),
            overrides: ["Cmd": ["echo", "hi"], "Env": [String](), "User": "", "Hostname": NSNull()],
            changes: []
        )
        #expect(composed["Cmd"] as? [String] == ["echo", "hi"])
        #expect(composed["Env"] as? [String] == ["A=1"])
        #expect(composed["User"] == nil)
        #expect(composed["Hostname"] == nil)
    }

    @Test("changes apply last, on top of the container's config")
    func changesApplyLast() throws {
        let composed = try CommitConfigComposer.compose(
            base: ["Cmd": ["/bin/sh"], "StopSignal": "SIGTERM"],
            container: container(["/bin/sh"], env: ["A=1"]),
            overrides: nil,
            changes: [#"CMD ["cat", "/data"]"#, "ENV B=2", "EXPOSE 8080", "LABEL x=y"]
        )
        #expect(composed["Cmd"] as? [String] == ["cat", "/data"])
        #expect(composed["Env"] as? [String] == ["A=1", "B=2"])
        #expect((composed["ExposedPorts"] as? [String: Any])?.keys.sorted() == ["8080/tcp"])
        #expect(composed["Labels"] as? [String: String] == ["x": "y"])
        #expect(composed["StopSignal"] as? String == "SIGTERM")
    }

    @Test("an invalid change is an error, not silently dropped")
    func invalidChange() {
        #expect(throws: DockerfileChangeError.self) {
            _ = try CommitConfigComposer.compose(base: [:], container: container(["/bin/sh"]), overrides: nil, changes: ["FROM alpine"])
        }
    }

    @Test("podman's INSTRUCTION=value shorthand and multi-line changes decode to Dockerfile syntax")
    func podmanChangesDecode() {
        #expect(
            LibpodCommitRoute.decodeChanges(["CMD=/bin/sh", "ENV FOO=bar", "LABEL a=b\nUSER=nobody", "  "])
                == ["CMD /bin/sh", "ENV FOO=bar", "LABEL a=b", "USER nobody"])
    }
}
