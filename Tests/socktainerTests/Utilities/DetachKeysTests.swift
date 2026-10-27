import Foundation
import Testing

@testable import socktainer

@Suite("Detach keys")
struct DetachKeysTests {

    @Test("parses moby's detach key syntax")
    func parse() {
        #expect(DetachKeys.parse(nil) == [0x10, 0x11])
        #expect(DetachKeys.parse("") == [0x10, 0x11])
        #expect(DetachKeys.parse("ctrl-p,ctrl-q") == [0x10, 0x11])
        #expect(DetachKeys.parse("ctrl-a,x") == [0x01, UInt8(ascii: "x")])
        #expect(DetachKeys.parse("ctrl-@,ctrl-[,ctrl-\\,ctrl-],ctrl-^,ctrl-_") == [0, 27, 28, 29, 30, 31])
        #expect(DetachKeys.parse("ctrl-Z") == [26])
        #expect(DetachKeys.parse("ctrl-1") == nil)
        #expect(DetachKeys.parse("ab") == nil)
        #expect(DetachKeys.parse("ctrl-p,") == nil)
    }

    @Test("the sequence detaches and is not forwarded")
    func detachSequence() {
        var scanner = DetachKeyScanner(sequence: [0x10, 0x11])
        let result = scanner.feed(Data([UInt8(ascii: "a"), 0x10, 0x11, UInt8(ascii: "b")]))
        #expect(result.detach)
        #expect(result.forward == Data([UInt8(ascii: "a")]))
    }

    @Test("a sequence split across reads still detaches")
    func splitSequence() {
        var scanner = DetachKeyScanner(sequence: [0x10, 0x11])
        let first = scanner.feed(Data([UInt8(ascii: "a"), 0x10]))
        #expect(!first.detach)
        #expect(first.forward == Data([UInt8(ascii: "a")]))
        let second = scanner.feed(Data([0x11]))
        #expect(second.detach)
        #expect(second.forward.isEmpty)
    }

    @Test("a broken prefix is forwarded unchanged")
    func brokenPrefix() {
        var scanner = DetachKeyScanner(sequence: [0x10, 0x11])
        let result = scanner.feed(Data([0x10, UInt8(ascii: "x"), 0x10, 0x10, 0x11]))
        #expect(result.detach)
        #expect(result.forward == Data([0x10, UInt8(ascii: "x"), 0x10]))

        var plain = DetachKeyScanner(sequence: [0x10, 0x11])
        let typed = plain.feed(Data("echo hi\r".utf8))
        #expect(!typed.detach)
        #expect(typed.forward == Data("echo hi\r".utf8))
    }

    @Test("a TTY handler hands its stdin writer off on detach instead of closing it")
    func handlerHandsOffWriter() throws {
        let handler = DockerTCPHandler(execId: "detach", ttyEnabled: true)
        let pipe = try #require(ProcessPipe.make())
        defer { try? pipe.read.close() }
        let handedOff = LockedBox<FileHandle?>(nil)
        handler.setDetachKeys([0x10, 0x11]) { handedOff.value = $0 }
        handler.setStdinWriter(pipe.write)

        let result = handler.scanForDetach(Data([UInt8(ascii: "h"), UInt8(ascii: "i"), 0x10, 0x11, UInt8(ascii: "z")]))
        #expect(result.detach)
        handler.drainForTesting()
        #expect(handedOff.value === pipe.write)

        // The writer still works: the process keeps its stdin.
        try pipe.write.write(contentsOf: Data("!".utf8))
        try pipe.write.close()
        #expect(String(data: pipe.read.readDataToEndOfFile(), encoding: .utf8) == "hi!")

        // Input after the detach is dropped.
        #expect(handler.scanForDetach(Data("more".utf8)).forward.isEmpty)
    }

    @Test("a non-TTY handler ignores detach keys, as Docker does")
    func nonTTYIgnoresDetachKeys() {
        let handler = DockerTCPHandler(execId: "detach", ttyEnabled: false)
        handler.setDetachKeys([0x10, 0x11]) { _ in }
        let result = handler.scanForDetach(Data([0x10, 0x11]))
        #expect(!result.detach)
        #expect(result.forward == Data([0x10, 0x11]))
    }

    @Test("a TTY client disconnecting hands the writer off; a non-TTY one closes it")
    func disconnectHandsOffTTYWriter() throws {
        let tty = DockerTCPHandler(execId: "detach", ttyEnabled: true)
        let ttyPipe = try #require(ProcessPipe.make())
        defer {
            try? ttyPipe.read.close()
            try? ttyPipe.write.close()
        }
        let handedOff = LockedBox<FileHandle?>(nil)
        tty.setDetachKeys([0x10, 0x11]) { handedOff.value = $0 }
        tty.setStdinWriter(ttyPipe.write)
        tty.simulateChannelInactive()
        tty.drainForTesting()
        #expect(handedOff.value === ttyPipe.write)

        let plain = DockerTCPHandler(execId: "plain", ttyEnabled: false)
        let plainPipe = try #require(ProcessPipe.make())
        defer { try? plainPipe.read.close() }
        let plainHandedOff = LockedBox<FileHandle?>(nil)
        plain.setDetachKeys([0x10, 0x11]) { plainHandedOff.value = $0 }
        plain.setStdinWriter(plainPipe.write)
        plain.simulateInputClosed()
        plain.drainForTesting()
        #expect(plainHandedOff.value == nil)
        // Closed: the reader sees EOF.
        #expect(plainPipe.read.readDataToEndOfFile().isEmpty)
    }

    @Test("a writer set after the detach is handed off, not closed")
    func lateWriterHandedOff() throws {
        let handler = DockerTCPHandler(execId: "detach", ttyEnabled: true)
        let pipe = try #require(ProcessPipe.make())
        defer {
            try? pipe.read.close()
            try? pipe.write.close()
        }
        let handedOff = LockedBox<FileHandle?>(nil)
        handler.setDetachKeys([0x10, 0x11]) { handedOff.value = $0 }
        #expect(handler.scanForDetach(Data([0x10, 0x11])).detach)
        handler.simulateChannelInactive()
        handler.setStdinWriter(pipe.write)
        handler.drainForTesting()
        #expect(handedOff.value === pipe.write)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
