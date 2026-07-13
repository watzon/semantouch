import Foundation
import ComputerUseCore

// WindowCorrelation — match an Accessibility window to its ScreenCaptureKit
// counterpart using public signals only (docs/PROTOCOL.md §10.3). AX windows
// expose no WindowServer id through public API (the
// private `_AXUIElementGetWindow` is banned), so correlation reasons over owner
// pid, global frame, title, layer, and on-screen state.
//
// Correctness bar: ZERO wrong matches. Frame equality (within a rounding
// tolerance) is the dominant discriminator; title corroborates but is NOT required
// (titles legitimately mismatch); layer/on-screen only break residual ties. When
// signals cannot single out one window the engine returns `ambiguous_window` (many
// plausible) or `uncorrelated_window` (no plausible counterpart) rather than
// guessing. Every successful match records which signals decided it.

/// The Accessibility side of a correlation: what public AX gives us about a window.
public struct AXWindowDescriptor: Equatable, Sendable {
    /// Owning process id (must match the candidate's `ownerPID`).
    public var pid: Int32
    /// Global window frame in points (G, top-left) from `AXPosition`/`AXSize`.
    public var frame: Rect
    /// `AXTitle`, when present. May legitimately differ from the SCWindow title.
    public var title: String?

    public init(pid: Int32, frame: Rect, title: String? = nil) {
        self.pid = pid
        self.frame = frame
        self.title = title
    }

    /// Project to an error-payload `WindowRef` on the AX side (§6). Qualified:
    /// bare `WindowRef` collides with a Quickdraw typedef reachable through
    /// ScreenCaptureKit → ApplicationServices.
    public var axRef: ComputerUseCore.WindowRef {
        ComputerUseCore.WindowRef(windowId: nil, title: title, framePoints: frame, pid: Int(pid), source: .ax)
    }
}

/// How much a successful match can be trusted. `low` means only weak signals
/// (layer/on-screen) separated the winner from its rivals; the caller SHOULD add a
/// `low_correlation_confidence` state warning (§4.1) in that case.
public enum CorrelationConfidence: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: CorrelationConfidence, rhs: CorrelationConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A successful correlation: the chosen window, the ordered log of signals that
/// decided it, and the confidence.
public struct CorrelationMatch: Equatable, Sendable {
    public let window: WindowInfo
    public let signals: [String]
    public let confidence: CorrelationConfidence

    public init(window: WindowInfo, signals: [String], confidence: CorrelationConfidence) {
        self.window = window
        self.signals = signals
        self.confidence = confidence
    }
}

/// Canonical signal names recorded in the correlation log and in
/// `uncorrelated_window.data.signalsTried` (§6).
public enum CorrelationSignal {
    public static let pid = "pid"
    public static let frame = "frame"
    public static let title = "title"
    public static let layer = "layer"
    public static let onscreen = "onscreen"
}

public enum WindowCorrelation {
    /// Frame-component tolerance in points, absorbing point/pixel rounding between
    /// the AX and CGWindowList reports (§10.3).
    public static let defaultFrameTolerance = 2.0

    /// Correlate `ax` with one of `candidates` (a catalog's unified records). On
    /// success returns the winning `WindowInfo` plus the deciding-signal log; on
    /// failure returns a typed `ambiguous_window` / `uncorrelated_window` (§6).
    ///
    /// - `app` is the caller's app query, echoed into error payloads.
    /// - `frameTolerance` overrides the default rounding tolerance.
    public static func correlate(
        ax: AXWindowDescriptor,
        candidates: [WindowInfo],
        app: String,
        frameTolerance: Double = defaultFrameTolerance
    ) -> Result<CorrelationMatch, CUError> {
        var signalsTried: [String] = [CorrelationSignal.pid]

        // Hard gate: owner pid must match.
        let pidMatches = candidates.filter { $0.ownerPID == ax.pid }
        guard !pidMatches.isEmpty else {
            return .failure(.uncorrelatedWindow(
                app: app, ax: ax.axRef, sc: nil, signalsTried: signalsTried
            ))
        }

        // Primary discriminator: frame equality within tolerance.
        signalsTried.append(CorrelationSignal.frame)
        let frameMatches = pidMatches.filter {
            framesEqual(ax.frame, $0.bounds, tolerance: frameTolerance)
        }
        guard !frameMatches.isEmpty else {
            // No frame agreement: do not guess from title alone. Surface the lone
            // pid candidate (if unique) as diagnostic context.
            let scGuess = pidMatches.count == 1 ? pidMatches[0].screenCaptureKitRef : nil
            return .failure(.uncorrelatedWindow(
                app: app, ax: ax.axRef, sc: scGuess, signalsTried: signalsTried
            ))
        }

        var pool = frameMatches
        var deciding: [String] = [CorrelationSignal.pid, CorrelationSignal.frame]
        var confidence: CorrelationConfidence = .high
        let axTitle = normalizedTitle(ax.title)

        if pool.count > 1 {
            // Disambiguate multiple frame matches by title, then layer, then screen.
            signalsTried.append(CorrelationSignal.title)
            if let axTitle {
                let titled = pool.filter { normalizedTitle($0.title) == axTitle }
                if titled.count >= 1, titled.count < pool.count {
                    pool = titled
                    deciding.append(CorrelationSignal.title)
                }
            }
        } else if let axTitle, let candidateTitle = normalizedTitle(pool[0].title) {
            // Single frame match: title only calibrates confidence / corroborates.
            if candidateTitle == axTitle {
                deciding.append(CorrelationSignal.title)
            } else {
                // Frame agrees but the title disagrees — legitimate, but softer.
                confidence = min(confidence, .medium)
            }
        }

        if pool.count > 1 {
            signalsTried.append(CorrelationSignal.layer)
            let layerZero = pool.filter { $0.layer == 0 }
            if layerZero.count >= 1, layerZero.count < pool.count {
                pool = layerZero
                deciding.append(CorrelationSignal.layer)
                confidence = min(confidence, .medium)
            }
        }

        if pool.count > 1 {
            signalsTried.append(CorrelationSignal.onscreen)
            let onscreen = pool.filter { $0.isOnscreen }
            if onscreen.count >= 1, onscreen.count < pool.count {
                pool = onscreen
                deciding.append(CorrelationSignal.onscreen)
                confidence = .low
            }
        }

        if pool.count == 1 {
            return .success(CorrelationMatch(
                window: pool[0], signals: deciding, confidence: confidence
            ))
        }

        // Still tied after every public signal → ambiguous, do not choose.
        return .failure(.ambiguousWindow(
            app: app, candidates: pool.map { $0.screenCaptureKitRef }
        ))
    }

    // MARK: - Pure helpers

    /// Two frames are equal when every component differs by ≤ `tolerance` points.
    public static func framesEqual(_ a: Rect, _ b: Rect, tolerance: Double) -> Bool {
        abs(a.x - b.x) <= tolerance
            && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    /// Trim a title to a comparable form; `nil`/empty/whitespace → `nil`.
    static func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
