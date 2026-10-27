import ContainerAPIClient
import ContainerResource
import Foundation

public enum MobyContainerStatus {
    public static func toMobyState(_ appleStatus: RuntimeStatus) -> String {
        switch appleStatus {
        case .running:
            return "running"
        case .stopped:
            return "exited"
        case .stopping:
            return "exited"
        case .unknown:
            return "created"
        }
    }
}

/// Extension to RuntimeStatus to add Moby-compliant properties
extension RuntimeStatus {
    public var mobyState: String {
        MobyContainerStatus.toMobyState(self)
    }
}

extension ContainerSnapshot {
    /// Carries the last start time of a container socktainer rebuilt under a new name: the rebuilt
    /// container has no start date of its own until it boots again.
    static let startedAtLabel = "socktainer.started-at"

    /// When the container last started, from the runtime or, for a renamed one, the label.
    var lastStartedDate: Date? {
        startedDate ?? configuration.labels[Self.startedAtLabel].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// Apple Container reports both a never-started container and one that has exited as `stopped`;
    /// only the latter has a start date. Docker calls the former `created`.
    var isNeverStarted: Bool { status == .stopped && lastStartedDate == nil }

    /// Docker's state for this container (`created` / `running` / `paused` / `exited`).
    var mobyState: String {
        if isNeverStarted { return "created" }
        return ContainerPauseState.shared.isPaused(self) ? "paused" : status.mobyState
    }
}
