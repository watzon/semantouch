import Foundation
import ApplicationServices
import CoreGraphics
import Security
import ComputerUseCore
import MCPServer

/// Builds the read-only `DoctorResult` (§4.1): Accessibility + Screen Recording
/// grant status, the helper binary identity, and exact remediation.
///
/// **Prompt discipline.** With `requestOnboarding == false` (the default) this uses
/// only the *preflight* APIs — `AXIsProcessTrusted()` and
/// `CGPreflightScreenCaptureAccess()` — neither of which shows an OS dialog. Only
/// when the caller explicitly opts into onboarding does it call the prompting
/// variants (`AXIsProcessTrustedWithOptions(prompt:true)` /
/// `CGRequestScreenCaptureAccess()`). This satisfies "MUST NOT trigger any OS
/// permission prompt unless requestOnboarding is true".
public enum DoctorService {
    /// Compute the doctor report. `requestOnboarding` gates any OS prompt.
    public static func run(requestOnboarding: Bool = false) -> DoctorResult {
        let accessibility = accessibilityStatus(requestOnboarding: requestOnboarding)
        let screenRecording = screenRecordingStatus(requestOnboarding: requestOnboarding)

        let path = helperPath()
        let helper = DoctorResult.HelperInfo(
            path: path,
            signed: isValidlySigned(),
            version: MCPServer.serverVersion
        )

        let ready = accessibility == .granted && screenRecording == .granted
        let remediation = remediationSteps(
            path: path,
            accessibility: accessibility,
            screenRecording: screenRecording
        )

        return DoctorResult(
            helper: helper,
            accessibility: accessibility,
            screenRecording: screenRecording,
            ready: ready,
            remediation: remediation
        )
    }

    // MARK: - Permission probes

    /// Accessibility trust. Preflight (`AXIsProcessTrusted`) never prompts; the
    /// onboarding path uses the prompting options variant.
    static func accessibilityStatus(requestOnboarding: Bool) -> PermissionStatus {
        if requestOnboarding {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let options = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        }
        return AXIsProcessTrusted() ? .granted : .denied
    }

    /// Screen Recording grant. `CGPreflightScreenCaptureAccess()` reports current
    /// status without prompting; the onboarding path requests access (which prompts
    /// once). Both are public CoreGraphics APIs.
    static func screenRecordingStatus(requestOnboarding: Bool) -> PermissionStatus {
        if requestOnboarding {
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        }
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    // MARK: - Helper identity

    /// The running helper binary path (names the exact binary each grant applies to).
    public static func helperPath() -> String {
        Bundle.main.executablePath
            ?? CommandLine.arguments.first
            ?? "semantouch"
    }

    /// Best-effort code-signature validity of the running process, via the public
    /// Security framework (`SecCodeCopySelf` + `SecCodeCheckValidity`). Ad-hoc
    /// signatures (as produced by a local `swift build` on Apple Silicon) count as
    /// signed; a fully unsigned or tampered binary does not. Never throws.
    static func isValidlySigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    // MARK: - Remediation

    /// Exact, ordered remediation steps. Each grant that is not `granted` contributes
    /// steps that name the binary at `path`. When both are granted the list is empty.
    static func remediationSteps(
        path: String,
        accessibility: PermissionStatus,
        screenRecording: PermissionStatus
    ) -> [String] {
        var steps: [String] = []
        if accessibility != .granted {
            steps.append("Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable \"\(path)\".")
        }
        if screenRecording != .granted {
            steps.append("Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable \"\(path)\".")
        }
        if !steps.isEmpty {
            steps.append("Restart \"\(path)\" so the new grants take effect.")
        }
        return steps
    }
}
