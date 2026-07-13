import Foundation

/// A JSON value carried by a logged event's optional `value` field.
enum EventValue {
    case string(String)
    case int(Int)
    case bool(Bool)

    /// Render as a raw JSON fragment (strings are quoted+escaped; ints/bools raw).
    var jsonFragment: String {
        switch self {
        case .string(let s): return "\"\(EventLog.escape(s))\""
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

/// Appends one JSON object per line to the `--state-file`, flushed immediately so a
/// separate test process can observe each state change as it happens.
///
/// Line shape: `{"seq":N,"event":"...","control":"...","value":<optional>}`
///
/// `seq` is a monotonically increasing 1-based counter. Writes are serialized on a
/// private queue so the counter stays consistent even if events arrive off the main
/// thread. When no state file is configured, every call is a no-op.
final class EventLog {
    private let handle: FileHandle?
    private var seq: Int = 0
    private let queue = DispatchQueue(label: "dev.watzon.semantouch.fixture.eventlog")

    init(path: String?) {
        guard let path else {
            handle = nil
            return
        }
        // Truncate/create the file so each run starts clean.
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        let h = FileHandle(forWritingAtPath: path)
        if h == nil {
            warn("could not open state file for writing: \(path)")
        }
        handle = h
    }

    /// Append one event line and flush it to the kernel immediately.
    func log(_ event: String, control: String, value: EventValue? = nil) {
        queue.sync {
            seq += 1
            let line = Self.line(seq: seq, event: event, control: control, value: value)
            guard let handle else { return }
            handle.write(Data(line.utf8))
            // FileHandle.write is an unbuffered write() syscall, so the bytes are in
            // the kernel and visible to other processes without an explicit flush.
        }
    }

    static func line(seq: Int, event: String, control: String, value: EventValue?) -> String {
        var parts = [
            "\"seq\":\(seq)",
            "\"event\":\"\(escape(event))\"",
            "\"control\":\"\(escape(control))\"",
        ]
        if let value {
            parts.append("\"value\":\(value.jsonFragment)")
        }
        return "{" + parts.joined(separator: ",") + "}\n"
    }

    /// Minimal JSON string escaping (RFC 8259).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
