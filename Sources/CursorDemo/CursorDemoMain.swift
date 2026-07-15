import Foundation
import Darwin

// semantouch-cursor-demo — offline, decorative virtual-cursor artifact.
//
// Pure CursorAnimator + CursorArt render frames → one self-contained HTML/SVG
// file. No AppKit, no windows, no TCC, no input synthesis, no network. The
// overlay is decorative only: this CLI never moves the real pointer and never
// gates actions.

@main
enum CursorDemoMain {
    static func main() {
        switch DemoCLI.parse(CommandLine.arguments) {
        case .help:
            FileHandle.standardOutput.write(Data(DemoCLI.helpText.utf8))
            // --help has no side effects and exits successfully.
            exit(0)

        case .error(let message, let code):
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            FileHandle.standardError.write(Data(DemoCLI.usageHint.utf8))
            exit(Int32(code))

        case .run(let options):
            do {
                let html = DemoRenderer.render(frameCount: options.frameCount)
                try writeAtomically(html, to: options.outputPath)
                // stdout carries only the final output path.
                FileHandle.standardOutput.write(Data("\(options.outputPath)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("error: failed to write \(options.outputPath): \(error.localizedDescription)\n".utf8)
                )
                exit(2)
            }
        }
    }
}

// MARK: - CLI

private enum DemoCLI {
    static let defaultFrames = 180
    /// Upper bound keeps the artifact small and the offline render bounded.
    static let maxFrames = 2_400
    static let minFrames = 1

    static let helpText = """
    semantouch-cursor-demo — offline decorative virtual-cursor demo

    Generates a self-contained HTML/SVG artifact from CursorOverlay's pure
    CursorAnimator / CursorArt render frames. The virtual cursor is decorative
    only: it never moves the system pointer, never receives clicks, and never
    gates actions. No AppKit window, no TCC prompts, no network.

    Usage:
      semantouch-cursor-demo --output PATH [--frames N]
      semantouch-cursor-demo --help

    Options:
      --output PATH   Required. Destination HTML file path.
      --frames N      Optional positive frame count (default \(defaultFrames),
                      max \(maxFrames)). Fixed dt = 1/60 s. Script scales with N
                      (default includes moves + tip press/ripple; tiny N is honest).
      --help          Print this help and exit with no side effects.

    Exit codes:
      0  success (or --help)
      1  invalid arguments
      2  output write failure

    """

    static let usageHint = """
    usage: semantouch-cursor-demo --output PATH [--frames N]
           semantouch-cursor-demo --help

    """

    enum Result {
        case help
        case run(Options)
        case error(message: String, code: Int)
    }

    struct Options {
        let outputPath: String
        let frameCount: Int
    }

    static func parse(_ argv: [String]) -> Result {
        // Drop the executable name.
        let args = Array(argv.dropFirst())
        if args.isEmpty {
            return .error(message: "missing required --output PATH", code: 1)
        }

        var output: String?
        var frames: Int = defaultFrames
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                // Help wins even when mixed with other flags; no side effects.
                return .help

            case "--output":
                i += 1
                guard i < args.count else {
                    return .error(message: "--output requires a PATH", code: 1)
                }
                let path = args[i]
                if path.isEmpty || path.hasPrefix("-") {
                    return .error(message: "invalid --output path: \(path)", code: 1)
                }
                output = path

            case "--frames":
                i += 1
                guard i < args.count else {
                    return .error(message: "--frames requires a positive integer", code: 1)
                }
                guard let n = Int(args[i]), n >= minFrames, n <= maxFrames else {
                    return .error(
                        message: "--frames must be an integer in \(minFrames)…\(maxFrames)",
                        code: 1
                    )
                }
                frames = n

            default:
                if arg.hasPrefix("-") {
                    return .error(message: "unknown option: \(arg)", code: 1)
                }
                return .error(message: "unexpected argument: \(arg)", code: 1)
            }
            i += 1
        }

        guard let outputPath = output else {
            return .error(message: "missing required --output PATH", code: 1)
        }
        return .run(Options(outputPath: outputPath, frameCount: frames))
    }
}

// MARK: - Atomic write

private func writeAtomically(_ contents: String, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    if !directory.path.isEmpty && directory.path != "." {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    // Write via Data for explicit UTF-8 and atomic replace where possible.
    let data = Data(contents.utf8)
    try data.write(to: url, options: [.atomic])
}
