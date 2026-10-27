import Foundation
import Testing

@testable import socktainer

@Suite("Container stdin registry")
struct ContainerStdinRegistryTests {

    @Test("an attach writes through a duplicate; closing it keeps the process's stdin open")
    func duplicateKeepsStdinOpen() async throws {
        let registry = ContainerStdinRegistry()
        let pipe = try #require(ProcessPipe.make())
        defer { try? pipe.read.close() }
        await registry.park(id: "c1", writer: pipe.write)

        let attach = try #require(await registry.duplicateWriter(id: "c1"))
        try attach.write(contentsOf: Data("one ".utf8))
        try attach.close()

        let again = try #require(await registry.duplicateWriter(id: "c1"))
        try again.write(contentsOf: Data("two".utf8))
        try again.close()

        // Only closing the kept write end (the process exited) ends the stream.
        await registry.close(id: "c1")
        #expect(String(data: pipe.read.readDataToEndOfFile(), encoding: .utf8) == "one two")
        #expect(await registry.duplicateWriter(id: "c1") == nil)
    }

    @Test("a container created with OpenStdin is recognised by its label")
    func openStdinLabel() throws {
        let interactive = try makeContainerSnapshot(
            nativeId: "i1", ip: "192.168.64.30", network: "default", labels: [ContainerStdinRegistry.openStdinLabel: "true"])
        let plain = try makeContainerSnapshot(nativeId: "p1", ip: "192.168.64.31", network: "default", labels: [:])
        #expect(ContainerStdinRegistry.opensStdin(interactive))
        #expect(!ContainerStdinRegistry.opensStdin(plain))
    }
}
