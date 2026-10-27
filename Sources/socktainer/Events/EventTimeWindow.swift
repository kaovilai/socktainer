import Foundation

/// `since` / `until` window of an events request, in Unix nanoseconds.
///
/// Docker clients send `<seconds>[.<fraction>]` (the CLI resolves `5m` etc. itself,
/// moby `timetypes.ParseTimestamps`); podman clients forward the user's raw value,
/// which the podman server resolves with `util.ParseInputTime`: RFC 3339 / date
/// layouts, a Unix timestamp, or a Go duration (`since` = now - d, `until` = now + d).
/// Both forms are accepted on both routes.
struct EventTimeWindow: Equatable, Sendable {
    var since: Int64?
    var until: Int64?

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalid(field: String, value: String)
        case sinceAfterUntil

        var description: String {
            switch self {
            case .invalid(let field, let value): return "unable to convert \(field) time of \(value)"
            case .sinceAfterUntil: return "`since` time cannot be after `until` time"
            }
        }
    }

    static func parse(since: String?, until: String?, now: Date = Date()) throws -> EventTimeWindow {
        var window = EventTimeWindow()
        if let since, !since.isEmpty {
            guard let value = parseTime(since, isSince: true, now: now) else {
                throw ParseError.invalid(field: "since", value: since)
            }
            window.since = value
        }
        if let until, !until.isEmpty {
            guard let value = parseTime(until, isSince: false, now: now) else {
                throw ParseError.invalid(field: "until", value: until)
            }
            window.until = value
        }
        if let since = window.since, let until = window.until, until < since {
            throw ParseError.sinceAfterUntil
        }
        return window
    }

    /// Whether buffered events should be replayed before streaming. moby replays
    /// only when `since` or `until` is set.
    var wantsReplay: Bool { since != nil || until != nil }

    func contains(_ event: DockerEvent) -> Bool {
        let t = Int64(clamping: event.timeNano)
        if let since, t < since { return false }
        if let until, t > until { return false }
        return true
    }

    /// moby: an `until` already in the past means "print buffered events, then return".
    func onlyPast(now: Date = Date()) -> Bool {
        guard let until else { return false }
        return until < Self.nanos(now)
    }

    /// Nanoseconds from `now` until `until`, when it lies in the future.
    func remainingNanos(now: Date = Date()) -> UInt64? {
        guard let until else { return nil }
        let remaining = until - Self.nanos(now)
        return remaining > 0 ? UInt64(remaining) : nil
    }

    static func nanos(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    // MARK: - Parsing

    static func parseTime(_ raw: String, isSince: Bool, now: Date) -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let date = parseLayout(value) { return nanos(date) }
        if let unix = parseUnixTimestamp(value) { return unix }
        if let duration = parseGoDuration(value) {
            let base = nanos(now)
            return isSince ? base - duration : base + duration
        }
        return nil
    }

    /// `<seconds>[.<fraction>]`; the fraction is scaled to nanoseconds like moby's
    /// `parseTimestamp`.
    static func parseUnixTimestamp(_ value: String) -> Int64? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty, let seconds = Int64(first) else { return nil }
        var nanos: Int64 = 0
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
            let digits = String(fraction.prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            nanos = Int64(digits) ?? 0
        }
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        return seconds < 0 ? scaled - nanos : scaled + nanos
    }

    /// The layouts podman's `ParseInputTime` tries, in order.
    private static func parseLayout(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }

        // Go parses zone-less layouts as UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for layout in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-ddXXXXX", "yyyy-MM-dd"] {
            formatter.dateFormat = layout
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Go `time.ParseDuration`: optional sign, then one or more `<number><unit>`
    /// with units ns, us/µs, ms, s, m, h. A bare `0` is also valid.
    static func parseGoDuration(_ raw: String) -> Int64? {
        var s = Substring(raw)
        var sign: Double = 1
        if s.first == "-" || s.first == "+" {
            if s.first == "-" { sign = -1 }
            s = s.dropFirst()
        }
        if s == "0" { return 0 }
        guard !s.isEmpty else { return nil }

        let units: [(String, Double)] = [
            ("ns", 1), ("us", 1_000), ("µs", 1_000), ("μs", 1_000), ("ms", 1_000_000),
            ("s", 1_000_000_000), ("m", 60_000_000_000), ("h", 3_600_000_000_000),
        ]
        var total: Double = 0
        while !s.isEmpty {
            let number = s.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let magnitude = Double(number) else { return nil }
            s = s.dropFirst(number.count)
            // Longest unit first so "ms" is not read as "m" + "s".
            guard let unit = units.sorted(by: { $0.0.count > $1.0.count }).first(where: { s.hasPrefix($0.0) }) else {
                return nil
            }
            s = s.dropFirst(unit.0.count)
            total += magnitude * unit.1
        }
        guard total * sign < Double(Int64.max), total * sign > Double(Int64.min) else { return nil }
        return Int64(total * sign)
    }
}
