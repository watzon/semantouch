import AppKit
import Foundation

/// Parsed command-line configuration for the fixture app.
///
/// Flags (all optional):
///   --title T             window title for the main window (default "CU Fixture")
///   --state-file PATH      newline-delimited JSON event log destination
///   --frame x,y,w,h        main-window frame in screen points (AppKit bottom-left origin)
///   --cover x,y,w,h        spawn an opaque bright-orange borderless cover window at this frame
///   --second-window        spawn a second titled window ("CU Fixture B")
///   --activate             call NSApp.activate on launch (default: do NOT steal focus)
///
/// Both `--flag value` and `--flag=value` spellings are accepted. Unparseable
/// geometry is reported on stderr and ignored (the default is kept).
struct Config {
    var title: String = "CU Fixture"
    var stateFile: String? = nil
    var frame: NSRect = NSRect(x: 240, y: 240, width: 480, height: 640)
    var cover: NSRect? = nil
    var secondWindow: Bool = false
    var activate: Bool = false

    static func parse(_ argv: [String]) -> Config {
        var config = Config()
        // Drop argv[0] (the executable path).
        let args = Array(argv.dropFirst())

        func nextValue(for flag: String, from index: inout Int) -> String? {
            // Support `--flag=value`.
            if let eq = args[index].firstIndex(of: "=") {
                return String(args[index][args[index].index(after: eq)...])
            }
            // Support `--flag value`.
            guard index + 1 < args.count else {
                warn("missing value for \(flag)")
                return nil
            }
            index += 1
            return args[index]
        }

        var i = 0
        while i < args.count {
            let raw = args[i]
            let flag = raw.split(separator: "=", maxSplits: 1).first.map(String.init) ?? raw
            switch flag {
            case "--title":
                if let v = nextValue(for: flag, from: &i) { config.title = v }
            case "--state-file":
                if let v = nextValue(for: flag, from: &i) { config.stateFile = v }
            case "--frame":
                if let v = nextValue(for: flag, from: &i), let r = Config.parseRect(v) {
                    config.frame = r
                }
            case "--cover":
                if let v = nextValue(for: flag, from: &i), let r = Config.parseRect(v) {
                    config.cover = r
                }
            case "--second-window":
                config.secondWindow = true
            case "--activate":
                config.activate = true
            default:
                warn("ignoring unknown argument: \(raw)")
            }
            i += 1
        }
        return config
    }

    /// Parse "x,y,w,h" into an NSRect. Returns nil (and warns) on malformed input.
    static func parseRect(_ s: String) -> NSRect? {
        let parts = s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3])
        else {
            warn("could not parse rect '\(s)' (expected x,y,w,h)")
            return nil
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }
}

/// Log to stderr only. The fixture must never write to stdout.
func warn(_ message: String) {
    FileHandle.standardError.write(Data("computer-use-fixture: \(message)\n".utf8))
}
