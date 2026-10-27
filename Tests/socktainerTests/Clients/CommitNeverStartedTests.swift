import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import Crypto
import Foundation
import Testing

@testable import socktainer

@Suite("ClientArchiveService.exportChangeLayer on never-started containers")
struct CommitNeverStartedTests {

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func store(_ data: Data, in appSupport: URL) throws -> String {
        let digest = Self.digest(data)
        let dir = appSupport.appendingPathComponent("content/blobs/sha256")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(String(digest.dropFirst("sha256:".count))))
        return digest
    }

    @Test("a never-started container commits as its platform manifest plus an empty change layer")
    func emptyChangeLayer() async throws {
        let appSupport = FileManager.default.temporaryDirectory.appendingPathComponent("po-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let manifest = Data(#"{"schemaVersion":2,"config":{"digest":"sha256:00"},"layers":[]}"#.utf8)
        let manifestDigest = try Self.store(manifest, in: appSupport)
        let index = Data(
            """
            {"schemaVersion":2,"manifests":[
              {"digest":"sha256:\(String(repeating: "1", count: 64))","platform":{"architecture":"amd64","os":"linux"}},
              {"digest":"\(manifestDigest)","platform":{"architecture":"arm64","os":"linux","variant":"v8"}}
            ]}
            """.utf8)
        let indexDigest = try Self.store(index, in: appSupport)

        let proc = ProcessConfiguration(
            executable: "/bin/sh", arguments: [], environment: [], workingDirectory: "/", terminal: false, user: .id(uid: 0, gid: 0))
        let image = ImageDescription(
            reference: "alpine:latest",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.index.v1+json", digest: indexDigest, size: Int64(index.count)))
        var config = ContainerConfiguration(id: "po-never", image: image, process: proc)
        config.platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let container = ContainerSnapshot(configuration: config, status: .stopped, networks: [])

        let service = ClientArchiveService(appSupportPath: appSupport, flushGuest: { _ in })
        let layer = try #require(try await service.exportChangeLayer(container: container))
        defer { try? FileManager.default.removeItem(at: layer.tarPath) }
        #expect(layer.baseManifestDigest == manifestDigest)
        let reader = try ArchiveReader(file: layer.tarPath)
        var entries = 0
        for _ in reader { entries += 1 }
        #expect(entries == 0)
    }

    @Test("a manifest descriptor resolves to itself; an index to its platform entry")
    func platformManifestDigest() {
        let manifest = Data(#"{"layers":[]}"#.utf8)
        #expect(
            ClientArchiveService.platformManifestDigest(descriptorDigest: "sha256:m", blob: manifest, architecture: "arm64", os: "linux", variant: nil)
                == "sha256:m")
        let index = Data(
            #"{"manifests":[{"digest":"sha256:a","platform":{"architecture":"arm64","os":"linux","variant":"v7"}},{"digest":"sha256:b","platform":{"architecture":"arm64","os":"linux","variant":"v8"}}]}"#
                .utf8)
        #expect(
            ClientArchiveService.platformManifestDigest(descriptorDigest: "sha256:i", blob: index, architecture: "arm64", os: "linux", variant: "v8")
                == "sha256:b")
        #expect(
            ClientArchiveService.platformManifestDigest(descriptorDigest: "sha256:i", blob: index, architecture: "amd64", os: "linux", variant: nil)
                == nil)
    }
}
