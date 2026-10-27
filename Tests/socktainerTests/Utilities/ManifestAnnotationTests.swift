import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("ManifestAnnotation")
struct ManifestAnnotationTests {
    private let arm64 = Descriptor(
        mediaType: MediaTypes.imageManifest,
        digest: "sha256:" + String(repeating: "a", count: 64),
        size: 10,
        annotations: ["keep": "me"],
        platform: Platform(arch: "arm64", os: "linux")
    )
    private let amd64 = Descriptor(
        mediaType: MediaTypes.imageManifest,
        digest: "sha256:" + String(repeating: "b", count: 64),
        size: 10,
        platform: Platform(arch: "amd64", os: "linux")
    )

    @Test("instance fields update only that member's platform and annotations")
    func updatesInstance() throws {
        let index = Index(manifests: [arm64, amd64], annotations: ["index": "kept"])
        let annotation = ManifestAnnotation(variant: "v8", annotations: ["new": "value", "keep": "overwritten"])

        let updated = try annotation.apply(to: index, instanceDigest: arm64.digest)

        let member = updated.manifests[0]
        #expect(member.digest == arm64.digest)
        #expect(member.platform?.architecture == "arm64")
        #expect(member.platform?.os == "linux")
        #expect(member.platform?.variant == "v8")
        #expect(member.annotations == ["keep": "overwritten", "new": "value"])
        #expect(updated.manifests[1] == amd64)
        #expect(updated.annotations == ["index": "kept"])
    }

    @Test("arch and os overrides replace the member's platform")
    func overridesArchAndOS() throws {
        let index = Index(manifests: [amd64])
        let annotation = ManifestAnnotation(architecture: "arm", os: "freebsd")

        let updated = try annotation.apply(to: index, instanceDigest: amd64.digest)

        #expect(updated.manifests[0].platform?.architecture == "arm")
        #expect(updated.manifests[0].platform?.os == "freebsd")
    }

    @Test("no instance merges index annotations and leaves members alone")
    func updatesIndexAnnotations() throws {
        let index = Index(manifests: [arm64], annotations: ["a": "1", "b": "2"])
        let annotation = ManifestAnnotation(indexAnnotations: ["b": "3", "c": "4"])

        let updated = try annotation.apply(to: index, instanceDigest: nil)

        #expect(updated.annotations == ["a": "1", "b": "3", "c": "4"])
        #expect(updated.manifests == [arm64])
    }

    @Test("instance fields without an instance are rejected, as podman does")
    func instanceFieldsNeedInstance() {
        #expect(throws: ContainerizationError.self) {
            try ManifestAnnotation(architecture: "amd64").apply(to: Index(manifests: [amd64]), instanceDigest: nil)
        }
        #expect(throws: ContainerizationError.self) {
            try ManifestAnnotation(annotations: ["k": "v"]).apply(to: Index(manifests: [amd64]), instanceDigest: nil)
        }
    }

    @Test("index annotations with an instance are rejected, as podman does")
    func indexAnnotationsNeedNoInstance() {
        #expect(throws: ContainerizationError.self) {
            try ManifestAnnotation(indexAnnotations: ["k": "v"]).apply(to: Index(manifests: [amd64]), instanceDigest: amd64.digest)
        }
    }

    @Test("a digest that is not a member is rejected")
    func nonMemberRejected() {
        #expect(throws: ContainerizationError.self) {
            try ManifestAnnotation(variant: "v8").apply(to: Index(manifests: [amd64]), instanceDigest: arm64.digest)
        }
    }

    @Test(
        "platform fields the store cannot encode are rejected rather than dropped",
        arguments: [
            ManifestAnnotation(features: ["f"]),
            ManifestAnnotation(osFeatures: ["win32k"]),
            ManifestAnnotation(osVersion: "10.0"),
        ])
    func unencodablePlatformFieldsRejected(annotation: ManifestAnnotation) {
        #expect(throws: ContainerizationError.self) {
            try annotation.apply(to: Index(manifests: [amd64]), instanceDigest: amd64.digest)
        }
    }

    @Test("podman's body decodes case-insensitively, ignoring nulls")
    func decodesPodmanBody() throws {
        let body = Data(
            #"{"Operation":"annotate","All":null,"annotations":{"k":"v"},"index_annotations":null,"ARCH":"amd64","OS":"","Images":["x"]}"#.utf8)

        let (annotation, images) = try ManifestAnnotation.decode(podmanBody: body)

        #expect(annotation == ManifestAnnotation(architecture: "amd64", annotations: ["k": "v"]))
        #expect(images == ["x"])
    }

    @Test("an empty body decodes to no changes")
    func emptyBody() throws {
        let (annotation, images) = try ManifestAnnotation.decode(podmanBody: Data())
        #expect(annotation == ManifestAnnotation())
        #expect(images.isEmpty)
    }
}
