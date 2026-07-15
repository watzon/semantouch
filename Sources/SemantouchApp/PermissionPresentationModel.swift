import Foundation
import ComputerUseCore
import ComputerUseService

/// Pure, testable presentation state for the onboarding/status window.
///
/// No AppKit, no OS prompts, no timers. Callers feed passive `DoctorResult`
/// snapshots (from `DoctorService.run(requestOnboarding: false)`) and optional
/// `UpdateCheck` results; this type derives labels, readiness, remediation copy,
/// and quit-warning text only.
public struct PermissionPresentationModel: Equatable, Sendable {
    public var accessibility: PermissionStatus
    public var screenRecording: PermissionStatus
    public var helperPath: String
    public var helperSigned: Bool
    public var helperVersion: String
    public var remediation: [String]
    public var activeSessionCount: Int
    public var update: UpdateCheck?

    public init(
        accessibility: PermissionStatus = .unknown,
        screenRecording: PermissionStatus = .unknown,
        helperPath: String = "",
        helperSigned: Bool = false,
        helperVersion: String = "",
        remediation: [String] = [],
        activeSessionCount: Int = 0,
        update: UpdateCheck? = nil
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.helperPath = helperPath
        self.helperSigned = helperSigned
        self.helperVersion = helperVersion
        self.remediation = remediation
        self.activeSessionCount = activeSessionCount
        self.update = update
    }

    /// Build from a passive doctor snapshot. Never prompts.
    public init(doctor: DoctorResult, activeSessionCount: Int = 0, update: UpdateCheck? = nil) {
        self.init(
            accessibility: doctor.accessibility,
            screenRecording: doctor.screenRecording,
            helperPath: doctor.helper.path,
            helperSigned: doctor.helper.signed,
            helperVersion: doctor.helper.version,
            remediation: doctor.remediation,
            activeSessionCount: activeSessionCount,
            update: update
        )
    }

    // MARK: - Derived readiness

    /// Ready only when both TCC grants are `granted`.
    public var isReady: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    public var needsAccessibility: Bool {
        accessibility != .granted
    }

    public var needsScreenRecording: Bool {
        screenRecording != .granted
    }

    public var needsAnyPermission: Bool {
        needsAccessibility || needsScreenRecording
    }

    // MARK: - Permission labels / why-needed copy

    public var accessibilityStatusLabel: String {
        statusLabel(for: accessibility)
    }

    public var screenRecordingStatusLabel: String {
        statusLabel(for: screenRecording)
    }

    public var accessibilityWhyNeeded: String {
        "Semantouch reads UI structure and performs accessibility actions on the target app without taking over your desktop."
    }

    public var screenRecordingWhyNeeded: String {
        "Semantouch captures still images of target windows (including covered windows) via ScreenCaptureKit. After granting Screen Recording, quit and reopen Semantouch so the grant takes effect."
    }

    // MARK: - Signing / version

    public var signedStatusLabel: String {
        if helperSigned {
            return "Signed"
        }
        return "Not signed (ad-hoc or unsigned build)"
    }

    public var versionStatusLabel: String {
        if helperVersion.isEmpty {
            return "Version unknown"
        }
        return "Version \(helperVersion)"
    }

    public var appIdentityLabel: String {
        let path = helperPath.isEmpty ? "Semantouch" : helperPath
        return "\(path) · \(signedStatusLabel) · \(versionStatusLabel)"
    }

    // MARK: - Sessions / quit

    public var activeSessionsLabel: String {
        switch activeSessionCount {
        case 0:
            return "No active sessions"
        case 1:
            return "1 active session"
        default:
            return "\(activeSessionCount) active sessions"
        }
    }

    public var hasActiveSessions: Bool {
        activeSessionCount > 0
    }

    /// Shown when the user attempts to quit while sessions are live.
    public var quitWarningMessage: String {
        if activeSessionCount <= 0 {
            return ""
        }
        if activeSessionCount == 1 {
            return "1 automation session is still active. Quitting will end it."
        }
        return "\(activeSessionCount) automation sessions are still active. Quitting will end them."
    }

    // MARK: - Update labels

    public var updateStatusLabel: String {
        guard let update else {
            return "Update status not checked"
        }
        switch update.status {
        case .available:
            let latest = update.latestVersion.map { "v\($0)" } ?? "a newer release"
            return "Update available: \(latest) (current v\(update.currentVersion))"
        case .upToDate:
            return "Up to date (v\(update.currentVersion))"
        case .unknown:
            if let message = update.message, !message.isEmpty {
                return "Update check unavailable: \(message)"
            }
            return "Update check unavailable"
        }
    }

    // MARK: - Remediation

    /// Prefer doctor-provided remediation; fall back to path-aware steps when empty.
    public var remediationSteps: [String] {
        if !remediation.isEmpty {
            return remediation
        }
        return Self.defaultRemediationSteps(
            path: helperPath.isEmpty ? "Semantouch" : helperPath,
            accessibility: accessibility,
            screenRecording: screenRecording
        )
    }

    public var remediationSummary: String {
        remediationSteps.joined(separator: "\n")
    }

    public var readinessSummary: String {
        if isReady {
            return "Ready — Accessibility and Screen Recording are granted."
        }
        if needsAccessibility && needsScreenRecording {
            return "Not ready — grant Accessibility and Screen Recording."
        }
        if needsAccessibility {
            return "Not ready — grant Accessibility."
        }
        return "Not ready — grant Screen Recording (then quit and reopen)."
    }

    // MARK: - Passive refresh (never prompts)

    /// Apply a passive doctor snapshot. Callers MUST use
    /// `DoctorService.run(requestOnboarding: false)` for this path.
    public mutating func applyPassiveDoctor(_ doctor: DoctorResult) {
        accessibility = doctor.accessibility
        screenRecording = doctor.screenRecording
        helperPath = doctor.helper.path
        helperSigned = doctor.helper.signed
        helperVersion = doctor.helper.version
        remediation = doctor.remediation
    }

    public mutating func applyActiveSessionCount(_ count: Int) {
        activeSessionCount = max(0, count)
    }

    public mutating func applyUpdate(_ update: UpdateCheck?) {
        self.update = update
    }

    // MARK: - Helpers

    private func statusLabel(for status: PermissionStatus) -> String {
        switch status {
        case .granted:
            return "Granted"
        case .denied:
            return "Not granted"
        case .unknown:
            return "Unknown"
        }
    }

    /// Mirrors DoctorService remediation copy so presentation stays coherent when
    /// tests inject statuses without a live doctor run.
    public static func defaultRemediationSteps(
        path: String,
        accessibility: PermissionStatus,
        screenRecording: PermissionStatus
    ) -> [String] {
        var steps: [String] = []
        if accessibility != .granted {
            steps.append(
                "Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable \"\(path)\"."
            )
        }
        if screenRecording != .granted {
            steps.append(
                "Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable \"\(path)\"."
            )
            steps.append(
                "After enabling Screen Recording, quit and reopen \"\(path)\" so the grant takes effect."
            )
        } else if accessibility != .granted {
            steps.append("Restart \"\(path)\" so the new grants take effect.")
        }
        return steps
    }
}

// MARK: - Launch intent (pure)

public enum HostLaunchIntent {
    /// Best-effort: explicit user launch vs background/MCP spawn.
    /// `--background` / `--headless` / `SEMANTOUCH_BACKGROUND=1` / `SEMANTOUCH_MCP_SPAWN=1`
    /// mark non-interactive host starts (no window unless grants are missing).
    public static func isExplicitUserLaunch(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains("--background") || arguments.contains("--headless") {
            return false
        }
        if environment["SEMANTOUCH_BACKGROUND"] == "1" {
            return false
        }
        if environment["SEMANTOUCH_MCP_SPAWN"] == "1" {
            return false
        }
        // Default: treat as explicit so Finder double-click shows the window.
        return true
    }

    /// Explicit app launch always shows UI.
    /// Background/MCP launch shows UI only when a required grant is missing.
    public static func shouldShowOnboarding(
        isExplicitLaunch: Bool,
        model: PermissionPresentationModel
    ) -> Bool {
        isExplicitLaunch || model.needsAnyPermission
    }
}
