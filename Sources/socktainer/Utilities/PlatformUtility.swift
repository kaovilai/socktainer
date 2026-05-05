import ContainerAPIClient
import Containerization
import ContainerizationOCI
import Foundation
import Vapor

public typealias Platform = ContainerizationOCI.Platform

public func currentPlatform() -> Platform {
    Platform.current
}

public func platformOrThrow(_ platformString: String) throws -> Platform {
    let trimmed = platformString.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.first == "{" {
        guard let data = trimmed.data(using: .utf8) else {
            throw Abort(.badRequest, reason: "invalid JSON-encoded OCI platform object")
        }

        do {
            return try JSONDecoder().decode(Platform.self, from: data)
        } catch {
            throw Abort(.badRequest, reason: "invalid JSON-encoded OCI platform object")
        }
    }

    return try Platform(from: trimmed)
}

/// Parses a comma-separated platform specification string (e.g. "linux/arm64,linux/s390x")
/// into an array of `Platform` values. Trims whitespace around each entry.
/// Throws if the string is empty or any individual platform token is invalid.
public func parseMultiPlatformString(_ platformString: String) throws -> [Platform] {
    let parts =
        platformString
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !parts.isEmpty else {
        throw Abort(.badRequest, reason: "Empty platform specification")
    }

    return try parts.map { part in
        do {
            return try Platform(from: part)
        } catch {
            throw Abort(
                .badRequest,
                reason: "Unsupported platform '\(part)' (expected format: os/architecture, e.g. linux/arm64): \(error.localizedDescription)"
            )
        }
    }
}

/// Returns `true` when any of the requested platforms requires QEMU emulation inside
/// the BuildKit container VM – i.e. the platform is neither `arm64` (native on Apple
/// Silicon) nor `amd64` / `x86_64` (handled by Rosetta 2 on Apple Silicon).
public func platformsRequireQEMU(_ platforms: [Platform]) -> Bool {
    platforms.contains { platform in
        let arch = platform.architecture.lowercased()
        return arch != "arm64" && arch != "amd64" && arch != "x86_64"
    }
}

public func requestedOrDefaultPlatform(_ requestedPlatform: Platform?) -> Platform {
    requestedPlatform ?? Platform.current
}

public func preferredPlatformMatches(
    _ leftPlatform: Platform?,
    over rightPlatform: Platform?,
    preferredPlatform: Platform
) -> Bool {
    let leftExactMatch = leftPlatform == preferredPlatform
    let rightExactMatch = rightPlatform == preferredPlatform
    if leftExactMatch != rightExactMatch {
        return leftExactMatch
    }

    let leftArchitectureMatch = leftPlatform?.architecture == preferredPlatform.architecture
    let rightArchitectureMatch = rightPlatform?.architecture == preferredPlatform.architecture
    if leftArchitectureMatch != rightArchitectureMatch {
        return leftArchitectureMatch
    }

    let leftOSMatch = leftPlatform?.os == preferredPlatform.os
    let rightOSMatch = rightPlatform?.os == preferredPlatform.os
    if leftOSMatch != rightOSMatch {
        return leftOSMatch
    }

    return false
}
