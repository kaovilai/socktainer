import Foundation
import Vapor

/// `GET /containers/{id}/top` body: the column titles and one row of cells per process.
struct RESTContainerTop: Content, Equatable {
    let Titles: [String]
    let Processes: [[String]]
}

enum ContainerTopError: Error, Equatable {
    /// The `ps` output has no `PID` column, which Docker refuses as well.
    case noPIDColumn
    /// The `ps` output was empty.
    case noOutput
}

/// Builds the `ps` invocation `top` runs inside the container and parses what it prints.
///
/// Docker runs `ps` on the host and keeps the rows whose PID belongs to the container. Apple
/// containers run in their own VM, so socktainer runs `ps` inside the container instead (the
/// image must provide one, as busybox- and Debian-based images do) and drops the row of that
/// `ps` process itself.
enum ContainerTop {
    static let dockerDefaultPSArgs = "-ef"

    /// The command for Docker's `ps_args` (default `-ef`), split on whitespace like Docker does.
    static func dockerCommand(psArgs: String?) -> [String] {
        let args = (psArgs?.isEmpty == false ? psArgs! : dockerDefaultPSArgs)
        return ["ps"] + args.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Parses `ps` output the way Docker does: the titles are the header's fields, and each
    /// row's surplus fields are joined back into the last column (the command line, which may
    /// contain spaces). The row of the `ps` process that produced the output is dropped.
    static func parseDockerOutput(_ output: String, command: [String]) throws -> RESTContainerTop {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first else { throw ContainerTopError.noOutput }
        let titles = header.split(whereSeparator: \.isWhitespace).map(String.init)
        guard titles.contains("PID") else { throw ContainerTopError.noPIDColumn }

        var processes: [[String]] = lines.dropFirst().compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !fields.isEmpty else { return nil }
            guard fields.count > titles.count else { return fields }
            return Array(fields[..<(titles.count - 1)]) + [fields[(titles.count - 1)...].joined(separator: " ")]
        }
        dropSelf(from: &processes, commandColumn: titles.count - 1, command: command)
        return RESTContainerTop(Titles: titles, Processes: processes)
    }

    /// Removes the last row whose command column is exactly `command`: the `ps` that ran.
    static func dropSelf(from processes: inout [[String]], commandColumn: Int, command: [String]) {
        let commandLine = command.joined(separator: " ")
        if let index = processes.lastIndex(where: { $0.count > commandColumn && $0[commandColumn] == commandLine }) {
            processes.remove(at: index)
        }
    }

    // MARK: - libpod

    /// One podman (psgo) format descriptor: the title podman prints for it and the `ps -o` field
    /// that yields its value. `pcpu` has no field because busybox's `ps` lacks one; it is computed
    /// from `time` and `etime` the way psgo computes it.
    struct Descriptor: Sendable {
        let title: String
        let field: String?
    }

    /// psgo's descriptors, by both their normal and AIX names (`podman top -l` lists them). The
    /// host-side ones (`hpid`, `huser`, `hgroup`) report the in-VM values: the VM is the host the
    /// container's processes see.
    static let descriptors: [String: Descriptor] = {
        let table: [(names: [String], title: String, field: String?)] = [
            (["args", "%a"], "COMMAND", "args"),
            (["comm", "%c"], "COMMAND", "comm"),
            (["etime", "%t"], "ELAPSED", "etime"),
            (["group", "%G"], "GROUP", "group"),
            (["nice", "%n"], "NI", "nice"),
            (["pcpu", "%C"], "%CPU", nil),
            (["pgid", "%r"], "PGID", "pgid"),
            (["pid", "%p"], "PID", "pid"),
            (["ppid", "%P"], "PPID", "ppid"),
            (["rgroup", "%g"], "RGROUP", "rgroup"),
            (["ruser", "%u"], "RUSER", "ruser"),
            (["time", "%x"], "TIME", "time"),
            (["tty", "%y"], "TTY", "tty"),
            (["user", "%U"], "USER", "user"),
            (["vsz", "%z"], "VSZ", "vsz"),
            (["rss"], "RSS", "rss"),
            (["state"], "STATE", "stat"),
            (["hpid"], "HPID", "pid"),
            (["huser"], "HUSER", "user"),
            (["hgroup"], "HGROUP", "group"),
        ]
        var map: [String: Descriptor] = [:]
        for entry in table {
            for name in entry.names { map[name] = Descriptor(title: entry.title, field: entry.field) }
        }
        return map
    }()

    /// What `podman top` shows when given no descriptors (psgo's defaults).
    static let libpodDefaultDescriptors = ["user", "pid", "ppid", "pcpu", "etime", "tty", "time", "args"]

    /// A `ps -o` run that answers a list of podman descriptors.
    struct LibpodPlan: Equatable {
        let descriptors: [String]
        /// The `ps -o` fields, each once; any free-text field (`args`, `comm`) last.
        let fields: [String]
        var command: [String] { ["ps", "-o", fields.joined(separator: ",")] }
    }

    /// The descriptors podman sent: `ps_args` repeated, each possibly comma-separated. Empty
    /// means podman's defaults.
    static func libpodDescriptors(_ psArgs: [String]) -> [String] {
        let split = psArgs.flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        return split.isEmpty ? libpodDefaultDescriptors : split
    }

    /// The `ps -o` plan for `descriptors`, or nil when one is not a psgo descriptor: podman then
    /// runs `ps` with the descriptors as its arguments (`podman top ctr -ef`), as Docker does.
    static func libpodPlan(descriptors: [String]) -> LibpodPlan? {
        var fields: [String] = ["pid"]
        for name in descriptors {
            guard let descriptor = Self.descriptors[name] else { return nil }
            let needed = descriptor.field.map { [$0] } ?? ["time", "etime"]
            for field in needed where !fields.contains(field) { fields.append(field) }
        }
        // The process's command line goes last: it may contain spaces, and it identifies the
        // `ps` row to drop.
        fields.removeAll { $0 == "args" }
        if let comm = fields.firstIndex(of: "comm") { fields.append(fields.remove(at: comm)) }
        fields.append("args")
        return LibpodPlan(descriptors: descriptors, fields: fields)
    }

    /// Parses the output of `plan.command` into podman's titles and rows.
    static func parseLibpodOutput(_ output: String, plan: LibpodPlan) throws -> RESTContainerTop {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { throw ContainerTopError.noOutput }
        let fixed = plan.fields.count - 1
        var rows: [[String: String]] = lines.dropFirst().compactMap { line in
            let cells = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard cells.count >= fixed else { return nil }
            var row: [String: String] = [:]
            for (index, field) in plan.fields.dropLast().enumerated() { row[field] = cells[index] }
            row["args"] = cells[fixed...].joined(separator: " ")
            return row
        }
        let commandLine = plan.command.joined(separator: " ")
        if let index = rows.lastIndex(where: { $0["args"] == commandLine }) {
            rows.remove(at: index)
        }

        let titles = plan.descriptors.map { Self.descriptors[$0]?.title ?? $0.uppercased() }
        let processes = rows.map { row in
            plan.descriptors.map { name -> String in
                guard let descriptor = Self.descriptors[name] else { return "" }
                guard let field = descriptor.field else {
                    return pcpu(time: row["time"] ?? "", etime: row["etime"] ?? "")
                }
                return row[field] ?? ""
            }
        }
        return RESTContainerTop(Titles: titles, Processes: processes)
    }

    /// psgo's `%CPU`: CPU time over elapsed time, as a percentage with three decimals.
    static func pcpu(time: String, etime: String) -> String {
        guard let cpu = seconds(time), let elapsed = seconds(etime), elapsed > 0 else { return "0.000" }
        return String(format: "%.3f", cpu / elapsed * 100)
    }

    /// Seconds in a `ps` duration: `[[DD-]HH:]MM:SS` (procps and busybox `time`/`etime`), or a
    /// bare number of seconds.
    static func seconds(_ duration: String) -> Double? {
        var rest = Substring(duration)
        var days = 0.0
        if let dash = rest.firstIndex(of: "-") {
            guard let value = Double(rest[..<dash]) else { return nil }
            days = value
            rest = rest[rest.index(after: dash)...]
        }
        var total = 0.0
        for part in rest.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return days * 86_400 + total
    }
}
