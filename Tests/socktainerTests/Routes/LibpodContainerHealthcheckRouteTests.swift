import ContainerAPIClient
import ContainerResource
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import socktainer

private func healthcheckLabel(_ test: [String], retries: Int? = 3) throws -> [String: String] {
    let config = HealthcheckConfig(Test: test, Interval: 30_000_000_000, Timeout: 5_000_000_000, Retries: retries, StartPeriod: nil)
    return [HealthCheckManager.healthcheckLabel: String(decoding: try JSONEncoder().encode(config), as: UTF8.self)]
}

private func withHealthcheckApp(
    labels: [String: String], status: RuntimeStatus = .running, exitCode: Int32,
    _ body: (Application, HealthCheckManager) async throws -> Void
) async throws {
    let snapshot = try makeContainerSnapshot(nativeId: "web", ip: "192.168.64.2", network: "default", labels: labels, status: status)
    let manager = HealthCheckManager(probe: { _, _, _ in exitCode })
    try await withApp(configure: { _ in }) { app in
        let regexRouter = app.regexRouter(with: app.logger)
        app.setRegexRouter(regexRouter)
        regexRouter.installMiddleware(on: app)
        app.middleware.use(ErrorMiddleware.default(environment: app.environment))
        app.storage[HealthCheckManagerKey.self] = manager
        try app.register(collection: LibpodContainerHealthcheckRoute(client: StaticSnapshotClientMock(snapshot: snapshot)))
        try await body(app, manager)
    }
}

@Suite("HealthCheckManager.runNow")
struct HealthCheckRunNowTests {
    private static let config = HealthcheckConfig(Test: ["CMD", "true"], Interval: nil, Timeout: nil, Retries: 2, StartPeriod: nil)

    @Test("A passing run records healthy with one log entry")
    func passing() async throws {
        let manager = HealthCheckManager(probe: { _, _, _ in 0 })
        let result = try #require(await manager.runNow(containerId: "c", config: Self.config))
        #expect(result.status == "healthy")
        #expect(result.health.Log.count == 1)
        #expect(result.health.Log.first?.ExitCode == 0)
        #expect(await manager.currentHealth(for: "c")?.Status == "healthy")
    }

    @Test("Failing runs report unhealthy each time, and the recorded status turns at Retries")
    func failing() async throws {
        let manager = HealthCheckManager(probe: { _, _, _ in 1 })
        let first = try #require(await manager.runNow(containerId: "c", config: Self.config))
        #expect(first.status == "unhealthy")
        #expect(first.health.Status == "starting")
        #expect(first.health.FailingStreak == 1)
        let second = try #require(await manager.runNow(containerId: "c", config: Self.config))
        #expect(second.health.Status == "unhealthy")
        #expect(second.health.FailingStreak == 2)
        #expect(second.health.Log.map(\.ExitCode) == [1, 1])
    }

    @Test("A disabled healthcheck does not run")
    func disabled() async {
        let manager = HealthCheckManager(probe: { _, _, _ in 0 })
        let none = HealthcheckConfig(Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        #expect(await manager.runNow(containerId: "c", config: none) == nil)
        #expect(await manager.currentHealth(for: "c") == nil)
    }
}

@Suite("LibpodContainerHealthcheckRoute")
struct LibpodContainerHealthcheckRouteTests {
    @Test("podman healthcheck run answers healthy and records it for inspect")
    func healthy() async throws {
        try await withHealthcheckApp(labels: try healthcheckLabel(["CMD-SHELL", "true"]), exitCode: 0) { app, manager in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/healthcheck") { res async throws in
                #expect(res.status == .ok)
                let results = try res.content.decode(LibpodHealthCheckResults.self)
                #expect(results.Status == "healthy")
                #expect(results.FailingStreak == 0)
                #expect(results.Log.count == 1)
            }
            #expect(await manager.currentHealth(for: "web")?.Status == "healthy")
        }
    }

    @Test("A failing check answers unhealthy with the failing streak")
    func unhealthy() async throws {
        try await withHealthcheckApp(labels: try healthcheckLabel(["CMD", "false"]), exitCode: 1) { app, _ in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/healthcheck") { res async throws in
                #expect(res.status == .ok)
                let results = try res.content.decode(LibpodHealthCheckResults.self)
                #expect(results.Status == "unhealthy")
                #expect(results.FailingStreak == 1)
                #expect(results.Log.first?.ExitCode == 1)
            }
        }
    }

    @Test("A container without a healthcheck is a conflict")
    func noHealthcheck() async throws {
        try await withHealthcheckApp(labels: [:], exitCode: 0) { app, _ in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/healthcheck") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("no defined healthcheck"))
            }
        }
    }

    @Test("A stopped container is a conflict")
    func stopped() async throws {
        try await withHealthcheckApp(labels: try healthcheckLabel(["CMD", "true"]), status: .stopped, exitCode: 0) { app, manager in
            try await app.testing().test(.GET, "/v5.0.0/libpod/containers/web/healthcheck") { res async in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("is not running"))
            }
            #expect(await manager.currentHealth(for: "web") == nil)
        }
    }
}
