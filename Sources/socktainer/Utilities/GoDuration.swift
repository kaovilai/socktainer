import Foundation

/// Go's `time.ParseDuration` syntax: an optionally signed sequence of decimal numbers, each
/// with an optional fraction and a unit suffix — "ns", "us" (or "µs"), "ms", "s", "m", "h" —
/// such as "250ms", "1.5s" or "1h30m". "0" alone needs no unit.
enum GoDuration {
    private static let units: [(suffix: String, nanoseconds: Double)] = [
        ("ns", 1), ("us", 1e3), ("µs", 1e3), ("μs", 1e3), ("ms", 1e6), ("s", 1e9), ("m", 60e9), ("h", 3600e9),
    ]

    /// The duration in seconds, or `nil` when `value` is not a Go duration.
    static func seconds(_ value: String) -> Double? {
        var rest = Substring(value)
        var sign = 1.0
        if let first = rest.first, first == "-" || first == "+" {
            sign = first == "-" ? -1 : 1
            rest = rest.dropFirst()
        }
        if rest == "0" { return 0 }
        guard !rest.isEmpty else { return nil }

        var total = 0.0  // nanoseconds
        while !rest.isEmpty {
            let number = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            guard !number.isEmpty, number != ".", number.filter({ $0 == "." }).count <= 1, let amount = Double(number) else {
                return nil
            }
            rest = rest.dropFirst(number.count)
            // Longest suffix first, so "ms" is not read as "m".
            guard let unit = units.filter({ rest.hasPrefix($0.suffix) }).max(by: { $0.suffix.count < $1.suffix.count }) else {
                return nil
            }
            rest = rest.dropFirst(unit.suffix.count)
            total += amount * unit.nanoseconds
        }
        return sign * total / 1e9
    }
}
