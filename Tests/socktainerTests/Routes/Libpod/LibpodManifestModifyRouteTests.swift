import ContainerizationError
import ContainerizationOCI
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

@Suite("LibpodManifestModifyRoute")
struct LibpodManifestModifyRouteTests {
    @Test("default operation (no 'operation' param) adds images, matching podman's 'update' default")
    func defaultOperationAdds() async throws {
        let receivedImages = Box<[String]?>(nil)
        let client = MockManifestClient(addHandler: { _, images in
            await receivedImages.set(images)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:added")
            }
        }
        #expect(await receivedImages.get() == ["alpine:latest"])
    }

    @Test("explicit operation=update adds images the same as the default")
    func explicitUpdateAdds() async throws {
        let addCalled = Box(false)
        let client = MockManifestClient(addHandler: { _, _ in
            await addCalled.set(true)
            return "sha256:added"
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=update&images=alpine:latest") { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await addCalled.get())
    }

    @Test("update with no images is a 400, not an empty no-op update")
    func updateWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("operation=remove removes every listed digest in a single batch call")
    func removeDigestsInOneBatch() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100),
                    Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:bbb", size: 100),
                ])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(body.ID == "sha256:afterremoval")
            }
        }
        #expect(await removedDigests.get() == ["sha256:aaa", "sha256:bbb"])
    }

    @Test("remove with no images is a 400")
    func removeWithNoImagesIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("a non-sha256 digest is rejected as unsupported, not silently mangled into a malformed sha256 value")
    func removeWithNonSha256DigestIs400() async throws {
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha512:abc") { res async throws in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("not a supported digest"))
            }
        }
    }

    @Test("a later invalid digest in a multi-digest remove is rejected before any digest is actually removed")
    func removeRejectsBeforeMutatingWhenADigestIsInvalid() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                // Only "sha256:aaa" is an actual member — "sha256:bbb" is not.
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(await removedDigests.get() + digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:bbb") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Neither digest was actually removed — validation ran before any mutation, even
        // though "sha256:aaa" alone would have succeeded if processed first.
        #expect(await removedDigests.get() == [])
    }

    @Test("a digest requested twice in the same remove is rejected before any digest is actually removed")
    func removeRejectsDuplicateDigestBeforeMutating() async throws {
        let removedDigests = Box<[String]>([])
        let client = MockManifestClient(
            inspectHandler: { _ in
                Index(manifests: [Descriptor(mediaType: MediaTypes.imageManifest, digest: "sha256:aaa", size: 100)])
            },
            removeDigestsHandler: { _, digests in
                await removedDigests.set(await removedDigests.get() + digests)
                return "sha256:afterremoval"
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=remove&images=sha256:aaa&images=sha256:aaa") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
        // Without the duplicate check, the first occurrence would succeed and the second
        // would fail (no longer a member after the first removal) — a partial mutation
        // masquerading as a whole-request failure, the exact bug this pre-check prevents.
        #expect(await removedDigests.get() == [])
    }

    @Test("operation=annotate applies podman's JSON body to each listed instance")
    func annotateAppliesBodyToInstance() async throws {
        let received = Box<[String: ManifestAnnotation]>([:])
        let client = MockManifestClient(annotateHandler: { _, instance, annotation in
            var seen = await received.get()
            seen[instance] = annotation
            await received.set(seen)
            return "sha256:annotated"
        })

        // Exactly what podman 6's bindings send: Go field names, no Content-Type.
        let body = #"{"Operation":"annotate","Annotations":{"k":"v"},"Arch":"arm64","Variant":"v8","OS":"linux","os_version":"1","os_features":["f"],"Images":["sha256:abc"]}"#
        try await withModifyApp(client: client) { app in
            try await app.testing().test(
                .PUT, "/v1.51/libpod/manifests/mylist?operation=annotate&images=sha256:abc",
                beforeRequest: { req in req.body = ByteBuffer(string: body) }
            ) { res async throws in
                #expect(res.status == .ok)
                let decoded = try JSONDecoder().decode(RESTManifestIDResponse.self, from: Data(buffer: res.body))
                #expect(decoded.ID == "sha256:annotated")
            }
        }
        let annotation = try #require(await received.get()["sha256:abc"])
        #expect(
            annotation
                == ManifestAnnotation(
                    architecture: "arm64", os: "linux", osVersion: "1", variant: "v8", osFeatures: ["f"], annotations: ["k": "v"]))
    }

    @Test("operation=annotate with podman's --index empty instance targets the index")
    func annotateIndexTargetsEmptyInstance() async throws {
        let instances = Box<[String]>([])
        let client = MockManifestClient(annotateHandler: { _, instance, annotation in
            #expect(annotation.indexAnnotations == ["org.example": "yes"])
            await instances.set(await instances.get() + [instance])
            return "sha256:annotated"
        })

        let body = #"{"Operation":"annotate","index_annotations":{"org.example":"yes"},"Images":[""]}"#
        try await withModifyApp(client: client) { app in
            try await app.testing().test(
                .PUT, "/v1.51/libpod/manifests/mylist?operation=annotate",
                beforeRequest: { req in req.body = ByteBuffer(string: body) }
            ) { res async throws in
                #expect(res.status == .ok)
            }
        }
        #expect(await instances.get() == [""])
    }

    @Test("operation=annotate rejecting the request surfaces as 400")
    func annotateInvalidArgumentIs400() async throws {
        let client = MockManifestClient(annotateHandler: { _, _, _ in
            throw ContainerizationError(.invalidArgument, message: "sha256:abc is not a member of mylist")
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(
                .PUT, "/v1.51/libpod/manifests/mylist?operation=annotate&images=sha256:abc",
                beforeRequest: { req in req.body = ByteBuffer(string: #"{"Arch":"amd64"}"#) }
            ) { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an unknown operation is a 400")
    func unknownOperationIs400() async throws {
        let client = MockManifestClient()

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?operation=bogus") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("an image add can't resolve surfaces as 400, not a raw error")
    func addNotFoundImageIs400() async throws {
        let client = MockManifestClient(addHandler: { _, _ in
            throw ClientImageError.notFound(id: "does-not-exist:latest")
        })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/mylist?images=does-not-exist:latest") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("removing from a nonexistent manifest list is a 404")
    func removeFromNonexistentManifestIs404() async throws {
        let client = MockManifestClient(
            inspectHandler: { name in throw ClientManifestError.notFound(name: name) },
            removeDigestsHandler: { name, _ in
                throw ClientManifestError.notFound(name: name)
            })

        try await withModifyApp(client: client) { app in
            try await app.testing().test(.PUT, "/v1.51/libpod/manifests/ghost?operation=remove&images=sha256:aaa") { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Helper

    private func withModifyApp(client: MockManifestClient, test: @escaping (Application) async throws -> Void) async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            try app.register(collection: LibpodManifestModifyRoute(client: client))
            try await test(app)
        }
    }
}
