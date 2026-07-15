import XCTest
import ComputerUseCore
import ComputerUseService
@testable import SemantouchApp

/// Pure, permission-free tests for `PermissionPresentationModel`.
/// No AppKit window construction, no OS prompts, no HostController I/O.
final class PermissionPresentationModelTests: XCTestCase {

    // MARK: - Grant combinations → readiness

    func testReadyOnlyWhenBothGranted() {
        let cases: [(PermissionStatus, PermissionStatus, Bool)] = [
            (.granted, .granted, true),
            (.granted, .denied, false),
            (.granted, .unknown, false),
            (.denied, .granted, false),
            (.denied, .denied, false),
            (.denied, .unknown, false),
            (.unknown, .granted, false),
            (.unknown, .denied, false),
            (.unknown, .unknown, false),
        ]
        for (ax, sr, expected) in cases {
            let model = PermissionPresentationModel(
                accessibility: ax,
                screenRecording: sr
            )
            XCTAssertEqual(
                model.isReady,
                expected,
                "ready mismatch for ax=\(ax.rawValue) sr=\(sr.rawValue)"
            )
            XCTAssertEqual(model.needsAccessibility, ax != .granted)
            XCTAssertEqual(model.needsScreenRecording, sr != .granted)
            XCTAssertEqual(model.needsAnyPermission, !expected)
        }
    }

    func testAllGrantCombinationsProduceDistinctStatusLabels() {
        for ax in PermissionStatus.allCases {
            for sr in PermissionStatus.allCases {
                let model = PermissionPresentationModel(
                    accessibility: ax,
                    screenRecording: sr
                )
                XCTAssertFalse(model.accessibilityStatusLabel.isEmpty)
                XCTAssertFalse(model.screenRecordingStatusLabel.isEmpty)
                if ax == .granted {
                    XCTAssertEqual(model.accessibilityStatusLabel, "Granted")
                } else if ax == .denied {
                    XCTAssertEqual(model.accessibilityStatusLabel, "Not granted")
                } else {
                    XCTAssertEqual(model.accessibilityStatusLabel, "Unknown")
                }
                if sr == .granted {
                    XCTAssertEqual(model.screenRecordingStatusLabel, "Granted")
                } else if sr == .denied {
                    XCTAssertEqual(model.screenRecordingStatusLabel, "Not granted")
                } else {
                    XCTAssertEqual(model.screenRecordingStatusLabel, "Unknown")
                }
            }
        }
    }

    // MARK: - Doctor snapshot mapping

    func testInitFromDoctorMapsFieldsAndReady() {
        let doctor = DoctorResult(
            helper: .init(
                path: "/Applications/Semantouch.app/Contents/MacOS/SemantouchHost",
                signed: true,
                version: "0.2.1"
            ),
            accessibility: .granted,
            screenRecording: .denied,
            ready: false,
            remediation: [
                "Grant Screen Recording: open System Settings › Privacy & Security › Screen Recording and enable \"/Applications/Semantouch.app/Contents/MacOS/SemantouchHost\"."
            ]
        )
        let model = PermissionPresentationModel(doctor: doctor, activeSessionCount: 2)
        XCTAssertEqual(model.helperPath, doctor.helper.path)
        XCTAssertEqual(model.helperSigned, true)
        XCTAssertEqual(model.helperVersion, "0.2.1")
        XCTAssertEqual(model.accessibility, .granted)
        XCTAssertEqual(model.screenRecording, .denied)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(model.activeSessionCount, 2)
        XCTAssertEqual(model.remediation, doctor.remediation)
    }

    func testApplyPassiveDoctorNeverRequiresPromptFlag() {
        // Contract: passive refresh only applies a DoctorResult already obtained
        // with requestOnboarding:false. The model itself has no prompt path.
        var model = PermissionPresentationModel(
            accessibility: .denied,
            screenRecording: .denied
        )
        let doctor = DoctorResult(
            helper: .init(path: "/tmp/SemantouchHost", signed: false, version: "0.2.1"),
            accessibility: .granted,
            screenRecording: .granted,
            ready: true,
            remediation: []
        )
        model.applyPassiveDoctor(doctor)
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(model.helperPath, "/tmp/SemantouchHost")
        XCTAssertEqual(model.helperSigned, false)
        XCTAssertTrue(model.remediation.isEmpty)
    }

    // MARK: - Remediation copy

    func testRemediationUsesDoctorStepsWhenPresent() {
        let steps = [
            "Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable \"/bin/host\".",
            "Restart \"/bin/host\" so the new grants take effect.",
        ]
        let model = PermissionPresentationModel(
            accessibility: .denied,
            screenRecording: .granted,
            helperPath: "/bin/host",
            remediation: steps
        )
        XCTAssertEqual(model.remediationSteps, steps)
        XCTAssertEqual(model.remediationSummary, steps.joined(separator: "\n"))
    }

    func testDefaultRemediationForMissingAccessibilityOnly() {
        let steps = PermissionPresentationModel.defaultRemediationSteps(
            path: "/Apps/Semantouch.app/Contents/MacOS/SemantouchHost",
            accessibility: .denied,
            screenRecording: .granted
        )
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps[0].contains("Accessibility"))
        XCTAssertTrue(steps[0].contains("/Apps/Semantouch.app/Contents/MacOS/SemantouchHost"))
        XCTAssertTrue(steps[1].contains("Restart"))
    }

    func testDefaultRemediationForMissingScreenRecordingMentionsQuitReopen() {
        let steps = PermissionPresentationModel.defaultRemediationSteps(
            path: "/Apps/Semantouch.app/Contents/MacOS/SemantouchHost",
            accessibility: .granted,
            screenRecording: .denied
        )
        XCTAssertGreaterThanOrEqual(steps.count, 2)
        XCTAssertTrue(steps.contains(where: { $0.contains("Screen Recording") }))
        XCTAssertTrue(
            steps.contains(where: {
                $0.localizedCaseInsensitiveContains("quit")
                    && $0.localizedCaseInsensitiveContains("reopen")
            }),
            "Screen Recording remediation must mention quit/reopen: \(steps)"
        )
    }

    func testDefaultRemediationForBothMissing() {
        let steps = PermissionPresentationModel.defaultRemediationSteps(
            path: "SemantouchHost",
            accessibility: .denied,
            screenRecording: .denied
        )
        XCTAssertTrue(steps.contains(where: { $0.contains("Accessibility") }))
        XCTAssertTrue(steps.contains(where: { $0.contains("Screen Recording") }))
        XCTAssertTrue(
            steps.contains(where: {
                $0.localizedCaseInsensitiveContains("quit")
                    && $0.localizedCaseInsensitiveContains("reopen")
            })
        )
    }

    func testRemediationEmptyWhenReadyAndNoDoctorSteps() {
        let model = PermissionPresentationModel(
            accessibility: .granted,
            screenRecording: .granted,
            helperPath: "/x",
            remediation: []
        )
        XCTAssertTrue(model.remediationSteps.isEmpty)
        XCTAssertEqual(model.remediationSummary, "")
    }

    func testWhyNeededCopyIsNonEmptyAndSRMentionsQuitReopen() {
        let model = PermissionPresentationModel()
        XCTAssertFalse(model.accessibilityWhyNeeded.isEmpty)
        XCTAssertFalse(model.screenRecordingWhyNeeded.isEmpty)
        XCTAssertTrue(model.screenRecordingWhyNeeded.localizedCaseInsensitiveContains("quit"))
        XCTAssertTrue(model.screenRecordingWhyNeeded.localizedCaseInsensitiveContains("reopen"))
    }

    // MARK: - Active-session quit warning

    func testQuitWarningEmptyWhenNoSessions() {
        let model = PermissionPresentationModel(activeSessionCount: 0)
        XCTAssertFalse(model.hasActiveSessions)
        XCTAssertEqual(model.quitWarningMessage, "")
        XCTAssertEqual(model.activeSessionsLabel, "No active sessions")
    }

    func testQuitWarningSingular() {
        let model = PermissionPresentationModel(activeSessionCount: 1)
        XCTAssertTrue(model.hasActiveSessions)
        XCTAssertEqual(model.activeSessionsLabel, "1 active session")
        XCTAssertTrue(model.quitWarningMessage.contains("1"))
        XCTAssertTrue(model.quitWarningMessage.localizedCaseInsensitiveContains("active"))
        XCTAssertTrue(model.quitWarningMessage.localizedCaseInsensitiveContains("quit"))
    }

    func testQuitWarningPlural() {
        let model = PermissionPresentationModel(activeSessionCount: 3)
        XCTAssertEqual(model.activeSessionsLabel, "3 active sessions")
        XCTAssertTrue(model.quitWarningMessage.contains("3"))
        XCTAssertTrue(model.quitWarningMessage.localizedCaseInsensitiveContains("sessions"))
    }

    func testApplyActiveSessionCountClampsNegative() {
        var model = PermissionPresentationModel(activeSessionCount: 2)
        model.applyActiveSessionCount(-4)
        XCTAssertEqual(model.activeSessionCount, 0)
        XCTAssertFalse(model.hasActiveSessions)
    }

    // MARK: - Update / status labels

    func testUpdateStatusNotChecked() {
        let model = PermissionPresentationModel(update: nil)
        XCTAssertEqual(model.updateStatusLabel, "Update status not checked")
    }

    func testUpdateStatusAvailable() {
        let model = PermissionPresentationModel(
            helperVersion: "0.2.1",
            update: UpdateCheck(
                currentVersion: "0.2.1",
                latestVersion: "0.3.0",
                status: .available
            )
        )
        let label = model.updateStatusLabel
        XCTAssertTrue(label.contains("Update available"), label)
        XCTAssertTrue(label.contains("0.3.0"), label)
        XCTAssertTrue(label.contains("0.2.1"), label)
    }

    func testUpdateStatusUpToDate() {
        let model = PermissionPresentationModel(
            update: UpdateCheck(
                currentVersion: "0.2.1",
                latestVersion: "0.2.1",
                status: .upToDate
            )
        )
        let label = model.updateStatusLabel
        XCTAssertTrue(label.contains("Up to date"), label)
        XCTAssertTrue(label.contains("0.2.1"), label)
    }

    func testUpdateStatusUnknownWithMessage() {
        let model = PermissionPresentationModel(
            update: UpdateCheck(
                currentVersion: "0.2.1",
                latestVersion: nil,
                status: .unknown,
                message: "network offline"
            )
        )
        let label = model.updateStatusLabel
        XCTAssertTrue(label.contains("unavailable"), label)
        XCTAssertTrue(label.contains("network offline"), label)
    }

    func testUpdateStatusUnknownWithoutMessage() {
        let model = PermissionPresentationModel(
            update: UpdateCheck(
                currentVersion: "0.2.1",
                latestVersion: nil,
                status: .unknown
            )
        )
        XCTAssertEqual(model.updateStatusLabel, "Update check unavailable")
    }

    func testSignedAndVersionLabels() {
        let signed = PermissionPresentationModel(
            helperPath: "/Apps/Semantouch.app/Contents/MacOS/SemantouchHost",
            helperSigned: true,
            helperVersion: "0.2.1"
        )
        XCTAssertEqual(signed.signedStatusLabel, "Signed")
        XCTAssertEqual(signed.versionStatusLabel, "Version 0.2.1")
        XCTAssertTrue(signed.appIdentityLabel.contains("Signed"))
        XCTAssertTrue(signed.appIdentityLabel.contains("0.2.1"))

        let unsigned = PermissionPresentationModel(helperSigned: false, helperVersion: "")
        XCTAssertTrue(unsigned.signedStatusLabel.localizedCaseInsensitiveContains("not signed"))
        XCTAssertEqual(unsigned.versionStatusLabel, "Version unknown")
    }

    func testReadinessSummaryCopy() {
        XCTAssertTrue(
            PermissionPresentationModel(accessibility: .granted, screenRecording: .granted)
                .readinessSummary.contains("Ready")
        )
        XCTAssertTrue(
            PermissionPresentationModel(accessibility: .denied, screenRecording: .denied)
                .readinessSummary.contains("Accessibility")
        )
        XCTAssertTrue(
            PermissionPresentationModel(accessibility: .denied, screenRecording: .granted)
                .readinessSummary.contains("Accessibility")
        )
        let srOnly = PermissionPresentationModel(accessibility: .granted, screenRecording: .denied)
        XCTAssertTrue(srOnly.readinessSummary.contains("Screen Recording"))
        XCTAssertTrue(srOnly.readinessSummary.localizedCaseInsensitiveContains("reopen"))
    }

    // MARK: - Launch-intent policy (pure)

    func testExplicitLaunchDetectionFlags() {
        XCTAssertFalse(
            HostLaunchIntent.isExplicitUserLaunch(
                arguments: ["SemantouchHost", "--background"],
                environment: [:]
            )
        )
        XCTAssertFalse(
            HostLaunchIntent.isExplicitUserLaunch(
                arguments: ["SemantouchHost", "--headless"],
                environment: [:]
            )
        )
        XCTAssertFalse(
            HostLaunchIntent.isExplicitUserLaunch(
                arguments: ["SemantouchHost"],
                environment: ["SEMANTOUCH_BACKGROUND": "1"]
            )
        )
        XCTAssertFalse(
            HostLaunchIntent.isExplicitUserLaunch(
                arguments: ["SemantouchHost"],
                environment: ["SEMANTOUCH_MCP_SPAWN": "1"]
            )
        )
        XCTAssertTrue(
            HostLaunchIntent.isExplicitUserLaunch(
                arguments: ["SemantouchHost"],
                environment: [:]
            )
        )
    }

    func testShouldShowOnboardingPolicy() {
        let ready = PermissionPresentationModel(
            accessibility: .granted,
            screenRecording: .granted
        )
        let missing = PermissionPresentationModel(
            accessibility: .denied,
            screenRecording: .granted
        )

        // Explicit launch always shows.
        XCTAssertTrue(HostLaunchIntent.shouldShowOnboarding(isExplicitLaunch: true, model: ready))
        XCTAssertTrue(HostLaunchIntent.shouldShowOnboarding(isExplicitLaunch: true, model: missing))

        // Background launch shows only when a grant is missing.
        XCTAssertFalse(HostLaunchIntent.shouldShowOnboarding(isExplicitLaunch: false, model: ready))
        XCTAssertTrue(HostLaunchIntent.shouldShowOnboarding(isExplicitLaunch: false, model: missing))
    }
}
