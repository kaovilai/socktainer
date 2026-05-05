import Testing

@testable import socktainer

@Suite("Platform parsing utilities")
struct PlatformParsingTests {

    // MARK: – parseMultiPlatformString

    @Test("Single platform is parsed correctly")
    func parsesSinglePlatform() throws {
        let platforms = try parseMultiPlatformString("linux/arm64")
        #expect(platforms.count == 1)
        #expect(platforms[0].architecture == "arm64")
        #expect(platforms[0].os == "linux")
    }

    @Test("Two comma-separated platforms are both parsed")
    func parsesTwoPlatforms() throws {
        let platforms = try parseMultiPlatformString("linux/arm64,linux/amd64")
        #expect(platforms.count == 2)
        #expect(platforms.map(\.architecture).contains("arm64"))
        #expect(platforms.map(\.architecture).contains("amd64"))
    }

    @Test("Three comma-separated platforms are all parsed")
    func parsesThreePlatforms() throws {
        let platforms = try parseMultiPlatformString("linux/arm64,linux/amd64,linux/s390x")
        #expect(platforms.count == 3)
    }

    @Test("Whitespace around platform tokens is trimmed")
    func trimsWhitespace() throws {
        let platforms = try parseMultiPlatformString(" linux/arm64 , linux/s390x ")
        #expect(platforms.count == 2)
        #expect(platforms[0].architecture == "arm64")
        #expect(platforms[1].architecture == "s390x")
    }

    @Test("ppc64le platform string is parsed")
    func parsesPpc64le() throws {
        let platforms = try parseMultiPlatformString("linux/ppc64le")
        #expect(platforms.count == 1)
        #expect(platforms[0].architecture == "ppc64le")
    }

    @Test("Empty string throws an error")
    func throwsOnEmptyString() {
        #expect(throws: Error.self) {
            _ = try parseMultiPlatformString("")
        }
    }

    @Test("Whitespace-only string throws an error")
    func throwsOnWhitespaceOnlyString() {
        #expect(throws: Error.self) {
            _ = try parseMultiPlatformString("   ")
        }
    }

    @Test("Invalid platform token throws an error")
    func throwsOnInvalidPlatform() {
        #expect(throws: Error.self) {
            _ = try parseMultiPlatformString("not-a-platform")
        }
    }

    @Test("Invalid token in a list throws an error")
    func throwsOnInvalidTokenInList() {
        #expect(throws: Error.self) {
            _ = try parseMultiPlatformString("linux/arm64,bad")
        }
    }

    // MARK: – platformsRequireQEMU

    @Test("arm64 alone does not require QEMU")
    func arm64NoQEMU() throws {
        let platform = try Platform(from: "linux/arm64")
        #expect(!platformsRequireQEMU([platform]))
    }

    @Test("amd64 alone does not require QEMU")
    func amd64NoQEMU() throws {
        let platform = try Platform(from: "linux/amd64")
        #expect(!platformsRequireQEMU([platform]))
    }

    @Test("s390x requires QEMU")
    func s390xRequiresQEMU() throws {
        let platform = try Platform(from: "linux/s390x")
        #expect(platformsRequireQEMU([platform]))
    }

    @Test("ppc64le requires QEMU")
    func ppc64leRequiresQEMU() throws {
        let platform = try Platform(from: "linux/ppc64le")
        #expect(platformsRequireQEMU([platform]))
    }

    @Test("riscv64 requires QEMU")
    func riscv64RequiresQEMU() throws {
        let platform = try Platform(from: "linux/riscv64")
        #expect(platformsRequireQEMU([platform]))
    }

    @Test("Mixed list with s390x requires QEMU")
    func mixedListWithS390xRequiresQEMU() throws {
        let arm64 = try Platform(from: "linux/arm64")
        let s390x = try Platform(from: "linux/s390x")
        #expect(platformsRequireQEMU([arm64, s390x]))
    }

    @Test("arm64 + amd64 together do not require QEMU")
    func nativePlatformsNoQEMU() throws {
        let arm64 = try Platform(from: "linux/arm64")
        let amd64 = try Platform(from: "linux/amd64")
        #expect(!platformsRequireQEMU([arm64, amd64]))
    }

    @Test("Empty platform list does not require QEMU")
    func emptyListNoQEMU() {
        #expect(!platformsRequireQEMU([]))
    }
}
