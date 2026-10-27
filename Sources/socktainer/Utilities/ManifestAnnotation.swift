import ContainerizationError
import ContainerizationOCI
import Foundation

/// The "annotate" operation of `PUT /libpod/manifests/{name}` (`podman manifest annotate`).
///
/// Mirrors libimage's `ManifestListAnnotateOptions`: with an instance, the platform fields
/// and `annotations` apply to that member's descriptor; without one (`--index`), only
/// `indexAnnotations` apply, to the index as a whole. Mixing the two scopes is rejected
/// with podman's own messages (`pkg/domain/infra/abi/manifest.go`'s `ManifestAnnotate`).
struct ManifestAnnotation: Sendable, Equatable {
    var architecture: String?
    var os: String?
    var osVersion: String?
    var variant: String?
    var features: [String] = []
    var osFeatures: [String] = []
    var annotations: [String: String] = [:]
    var indexAnnotations: [String: String] = [:]

    /// Real podman sends `ModifyOptions` as a JSON body (Go field names, a few with
    /// snake_case tags) without a Content-Type; its server decodes it with
    /// `encoding/json`, which matches keys case-insensitively — so this does too.
    static func decode(podmanBody data: Data) throws -> (annotation: ManifestAnnotation, images: [String]) {
        guard !data.isEmpty else { return (ManifestAnnotation(), []) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContainerizationError(.invalidArgument, message: "manifest modify body must be a JSON object")
        }
        var fields: [String: Any] = [:]
        for (key, value) in object where !(value is NSNull) {
            fields[key.lowercased()] = value
        }

        func string(_ key: String) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let string = value as? String else {
                throw ContainerizationError(.invalidArgument, message: "\(key) must be a string")
            }
            return string.isEmpty ? nil : string
        }
        func strings(_ key: String) throws -> [String] {
            guard let value = fields[key] else { return [] }
            guard let strings = value as? [String] else {
                throw ContainerizationError(.invalidArgument, message: "\(key) must be an array of strings")
            }
            return strings
        }
        func map(_ key: String) throws -> [String: String] {
            guard let value = fields[key] else { return [:] }
            guard let map = value as? [String: String] else {
                throw ContainerizationError(.invalidArgument, message: "\(key) must be an object of strings")
            }
            return map
        }

        let annotation = ManifestAnnotation(
            architecture: try string("arch"),
            os: try string("os"),
            osVersion: try string("os_version"),
            variant: try string("variant"),
            features: try strings("features"),
            osFeatures: try strings("os_features"),
            annotations: try map("annotations"),
            indexAnnotations: try map("index_annotations")
        )
        return (annotation, try strings("images"))
    }

    private var hasInstanceFields: Bool {
        architecture != nil || os != nil || osVersion != nil || variant != nil || !features.isEmpty || !osFeatures.isEmpty
            || !annotations.isEmpty
    }

    /// Returns `index` with this annotation applied to the member `instanceDigest`, or to
    /// the index itself when `instanceDigest` is nil. Existing annotations are kept and
    /// overwritten key by key, as libimage's `AnnotateInstance` does.
    func apply(to index: Index, instanceDigest: String?) throws -> Index {
        guard let instanceDigest else {
            if hasInstanceFields {
                throw ContainerizationError(
                    .invalidArgument, message: "setting a platform or annotation on an item in a manifest list requires an instance digest")
            }
            var annotations = index.annotations ?? [:]
            annotations.merge(indexAnnotations) { _, new in new }
            return Index(
                schemaVersion: index.schemaVersion, mediaType: index.mediaType, manifests: index.manifests,
                annotations: annotations.isEmpty ? nil : annotations, subject: index.subject, artifactType: index.artifactType)
        }

        guard indexAnnotations.isEmpty else {
            throw ContainerizationError(.invalidArgument, message: "setting index-wide annotation in a manifest list requires no instance digest")
        }
        // The image store's `Platform` neither models `features` nor encodes `os.version` /
        // `os.features`, so any of them would be silently dropped when the index is written.
        guard features.isEmpty, osFeatures.isEmpty, osVersion == nil else {
            throw ContainerizationError(
                .invalidArgument, message: "setting platform features, OS features or OS version is not supported by the image store")
        }
        guard let position = index.manifests.firstIndex(where: { $0.digest == instanceDigest }) else {
            throw ContainerizationError(.notFound, message: "\(instanceDigest) is not a member of the manifest list")
        }

        var updated = index
        var descriptor = updated.manifests[position]
        let current = descriptor.platform
        if architecture != nil || os != nil || variant != nil {
            descriptor.platform = Platform(
                arch: architecture ?? current?.architecture ?? "unknown",
                os: os ?? current?.os ?? "unknown",
                variant: variant ?? current?.variant
            )
        }
        if !annotations.isEmpty {
            var merged = descriptor.annotations ?? [:]
            merged.merge(annotations) { _, new in new }
            descriptor.annotations = merged
        }
        updated.manifests[position] = descriptor
        return updated
    }
}
