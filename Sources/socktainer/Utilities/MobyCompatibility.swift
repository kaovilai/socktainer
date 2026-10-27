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
    /// Apple Container reports both a never-started container and one that has exited as `stopped`;
    /// only the latter has a start date. Docker calls the former `created`.
    var isNeverStarted: Bool { status == .stopped && startedDate == nil }

    /// Docker's state for this container (`created` / `running` / `exited`).
    var mobyState: String { isNeverStarted ? "created" : status.mobyState }
}
