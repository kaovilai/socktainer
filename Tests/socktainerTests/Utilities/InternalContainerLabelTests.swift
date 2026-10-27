import ContainerAPIClient
import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("Internal container labels stay hidden")
struct InternalContainerLabelTests {

    private let stored: [String: String] = [
        "app": "web",
        ContainerCreateRoute.commandLabel: #"{"cmd":["sh"]}"#,
        LocalBindVolume.containerLabel: #"{"/srv":"po-bind"}"#,
        ContainerCreateRoute.portBindingsLabel: "{}",
        RestartPolicyManager.label: "always",
        HealthCheckManager.healthcheckLabel: "{}",
        "socktainer.dns.names": "web",
        ContainerStdinRegistry.openStdinLabel: "true",
        DockerContainerID.idSeedLabel: "seed",
        ContainerSnapshot.startedAtLabel: "1",
        ContainerCreateRoute.rewriteLoopbackLabel: "true",
        LibpodPodSchema.podLabel: "po-pod",
    ]

    @Test("user-visible labels drop bookkeeping labels but keep user and pod labels")
    func userLabels() {
        #expect(
            LabelNormalization.userContainerLabels(stored) == [
                "app": "web",
                ContainerCreateRoute.rewriteLoopbackLabel: "true",
                LibpodPodSchema.podLabel: "po-pod",
            ])
    }

    @Test(
        "label filters never match internal labels",
        arguments: ["socktainer.command", "socktainer.bind-volumes", "socktainer.port-bindings", "socktainer.restart-policy=always"])
    func filtersIgnoreInternal(filter: String) throws {
        let container = try makeContainerSnapshot(nativeId: "po-a", networks: [], labels: stored, status: .running)
        #expect(ClientContainerService.applyFilters([container], filters: ["label": [filter]]).isEmpty)
        #expect(ClientContainerService.applyFilters([container], filters: ["label": ["app=web"]]).count == 1)
    }

    @Test("create events carry only user-visible labels")
    func createEventLabels() throws {
        let container = try makeContainerSnapshot(nativeId: "po-a", networks: [], labels: stored, status: .running)
        let attributes = ContainerCreateRoute.makeCreateEvent(for: container).Actor.Attributes
        #expect(attributes["app"] == "web")
        #expect(attributes[ContainerCreateRoute.commandLabel] == nil)
        #expect(attributes[LocalBindVolume.containerLabel] == nil)
    }
}
