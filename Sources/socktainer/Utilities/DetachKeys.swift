import Foundation

/// Docker's detach key sequence: the bytes that, typed on an attached stdin, end the attach
/// and leave the container running instead of reaching it.
enum DetachKeys {
    /// Docker's and podman's default, `ctrl-p,ctrl-q`.
    static let defaultSequence: [UInt8] = [0x10, 0x11]

    /// Parses a `detachKeys` value the way moby's `term.ToBytes` does: comma-separated keys,
    /// each a single character or `ctrl-<c>` with `<c>` one of `a`-`z`, `@`, `[`, `\`, `]`,
    /// `^`, `_`. `nil` or an empty value selects the default; anything else invalid is `nil`.
    static func parse(_ value: String?) -> [UInt8]? {
        guard let value, !value.isEmpty else { return defaultSequence }
        var bytes: [UInt8] = []
        for key in value.split(separator: ",", omittingEmptySubsequences: false) {
            let key = key.trimmingCharacters(in: .whitespaces)
            if key.count == 1, let ascii = key.unicodeScalars.first, ascii.isASCII {
                bytes.append(UInt8(ascii.value))
                continue
            }
            guard key.lowercased().hasPrefix("ctrl-"), key.count == 6, let c = key.unicodeScalars.last else { return nil }
            switch c {
            case "a"..."z": bytes.append(UInt8(c.value) - 0x60)
            case "A"..."Z": bytes.append(UInt8(c.value) - 0x40)
            case "@", "[", "\\", "]", "^", "_": bytes.append(UInt8(c.value) - 0x40)
            default: return nil
            }
        }
        return bytes.isEmpty ? nil : bytes
    }
}

/// Watches an attached stdin stream for a detach key sequence, as moby's escape proxy does.
/// Bytes that could still begin the sequence are held back; once the sequence completes the
/// held bytes are dropped and the caller detaches, otherwise they are forwarded unchanged.
struct DetachKeyScanner {
    let sequence: [UInt8]
    private var matched = 0

    init(sequence: [UInt8]) {
        self.sequence = sequence
    }

    /// Feeds `data` from the client. Returns the bytes to forward to the container, and
    /// whether the detach sequence was typed (anything after it is discarded).
    mutating func feed(_ data: Data) -> (forward: Data, detach: Bool) {
        guard !sequence.isEmpty else { return (data, false) }
        var forward = Data()
        for byte in data {
            if byte == sequence[matched] {
                matched += 1
                if matched == sequence.count {
                    matched = 0
                    return (forward, true)
                }
                continue
            }
            // Mismatch: release what was held back, then retry this byte as a new start.
            forward.append(contentsOf: sequence[0..<matched])
            matched = 0
            if byte == sequence[0] {
                matched = 1
                if sequence.count == 1 { return (forward, true) }
            } else {
                forward.append(byte)
            }
        }
        return (forward, false)
    }
}
