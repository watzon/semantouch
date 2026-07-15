import Foundation
import XCTest
@testable import ComputerUseCore

final class PolicyEngineTests: XCTestCase {
    /// Canonical sensitive apps: primary bundle ID, display name, and path used for
    /// basename matching. Covers every built-in product once.
    private static let sensitiveApps: [(bundleId: String, displayName: String, path: String)] = [
        ("com.1password.1password", "1Password", "/Applications/1Password.app"),
        ("com.bitwarden.desktop", "Bitwarden", "/Applications/Bitwarden.app"),
        ("com.dashlane.dashlanephonefinal", "Dashlane", "/Applications/Dashlane.app"),
        ("com.lastpass.LastPass", "LastPass", "/Applications/LastPass.app"),
        ("com.nordsec.nordpass", "NordPass", "/Applications/NordPass.app"),
        ("me.proton.pass.electron", "Proton Pass", "/Applications/Proton Pass.app"),
    ]

    /// Additional stable identities that must also deny (legacy bundles / alternate names).
    private static let additionalSensitiveIdentities: [(bundleId: String?, displayName: String?, path: String?)] = [
        ("com.agilebits.onepassword7", "1Password 7", "/Applications/1Password 7.app"),
        ("com.dashlane.Dashlane", nil, nil),
        ("com.lastpass.lastpassmacdesktop", nil, nil),
        ("me.proton.pass.catalyst", "Proton Pass", nil),
    ]

    // MARK: - Non-sensitive default

    func testDefaultPolicyPermitsAnyObservedNonSensitiveApp() {
        let engine = PolicyEngine()
        let applications: [(String?, String?, String?)] = [
            ("com.example.app", "Example", "/Applications/Example.app"),
            ("com.apple.Terminal", "Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("com.apple.keychainaccess", "Keychain Access", "/System/Applications/Utilities/Keychain Access.app"),
            ("com.omp.app", "OMP", "/Applications/OMP.app"),
            ("dev.watzon.semantouch", "semantouch", "/opt/omp/bin/semantouch")
        ]

        for (bundleId, displayName, path) in applications {
            XCTAssertNil(engine.readDenialReason(bundleId: bundleId, displayName: displayName, path: path))
            XCTAssertNil(engine.mutationDenialReason(bundleId: bundleId, displayName: displayName, path: path))
        }
    }

    // MARK: - Built-in sensitive denylist

    func testDefaultPolicyDeniesEveryBuiltInByBundleId() {
        let engine = PolicyEngine()

        for app in Self.sensitiveApps {
            XCTAssertTrue(
                engine.isAppDenied(bundleId: app.bundleId, displayName: nil, path: nil),
                "bundle \(app.bundleId) should be denied"
            )
        }
        for identity in Self.additionalSensitiveIdentities {
            guard let bundleId = identity.bundleId else { continue }
            XCTAssertTrue(
                engine.isAppDenied(bundleId: bundleId, displayName: nil, path: nil),
                "bundle \(bundleId) should be denied"
            )
        }
    }

    func testDefaultPolicyDeniesEveryBuiltInByDisplayName() {
        let engine = PolicyEngine()

        for app in Self.sensitiveApps {
            XCTAssertTrue(
                engine.isAppDenied(bundleId: nil, displayName: app.displayName, path: nil),
                "display name \(app.displayName) should be denied"
            )
        }
        XCTAssertTrue(engine.isAppDenied(bundleId: nil, displayName: "1Password 7", path: nil))
    }

    func testDefaultPolicyDeniesEveryBuiltInByPathBasename() {
        let engine = PolicyEngine()

        for app in Self.sensitiveApps {
            XCTAssertTrue(
                engine.isAppDenied(bundleId: nil, displayName: nil, path: app.path),
                "path \(app.path) should be denied via basename"
            )
        }
        XCTAssertTrue(
            engine.isAppDenied(
                bundleId: nil,
                displayName: nil,
                path: "/Applications/1Password 7.app"
            )
        )
    }

    func testDefaultPolicyDeniesBuiltInsCaseInsensitively() {
        let engine = PolicyEngine()

        XCTAssertTrue(engine.isAppDenied(
            bundleId: "COM.1PASSWORD.1PASSWORD",
            displayName: nil,
            path: nil
        ))
        XCTAssertTrue(engine.isAppDenied(
            bundleId: nil,
            displayName: "bitwarden",
            path: nil
        ))
        XCTAssertTrue(engine.isAppDenied(
            bundleId: nil,
            displayName: nil,
            path: "/Applications/NORDPASS.APP"
        ))
    }

    func testDefaultPolicyDoesNotFalsePositiveOnSimilarNames() {
        let engine = PolicyEngine()
        let lookalikes: [(String?, String?, String?)] = [
            ("com.example.onepasswordhelper", "1Password Helper", "/Applications/1Password Helper.app"),
            ("com.example.bitwarden-cli", "Bitwarden CLI", "/Applications/Bitwarden CLI.app"),
            ("com.example.dashlane-notes", "Dashlane Notes", "/Applications/Dashlane Notes.app"),
            ("com.example.mylastpass", "My LastPass Vault", "/Applications/My LastPass Vault.app"),
            ("com.example.nordpass-business", "NordPass Business", "/Applications/NordPass Business.app"),
            ("com.example.proton-pass-export", "Proton Pass Export", "/Applications/Proton Pass Export.app"),
            ("com.apple.Passwords", "Passwords", "/System/Applications/Passwords.app"),
            ("com.example.password-manager", "Password Manager", "/Applications/Password Manager.app"),
        ]

        for (bundleId, displayName, path) in lookalikes {
            XCTAssertFalse(
                engine.isAppDenied(bundleId: bundleId, displayName: displayName, path: path),
                "lookalike \(displayName ?? bundleId ?? path ?? "?") must not match exact tokens"
            )
        }
    }

    func testDefaultPolicyReadAndMutationParityForSensitiveApps() {
        let engine = PolicyEngine()

        for app in Self.sensitiveApps {
            XCTAssertEqual(
                engine.readDenialReason(
                    bundleId: app.bundleId,
                    displayName: app.displayName,
                    path: app.path
                ),
                .appDenied
            )
            XCTAssertEqual(
                engine.mutationDenialReason(
                    bundleId: app.bundleId,
                    displayName: app.displayName,
                    path: app.path
                ),
                .appDenied
            )
        }
    }

    // MARK: - Operator-configured denylist

    func testDenylistBlocksReadsAndMutationsByBundleIdentifier() {
        let engine = PolicyEngine(appDenylist: ["com.example.private"])

        XCTAssertEqual(
            engine.readDenialReason(
                bundleId: "com.example.private",
                displayName: "Private",
                path: "/Applications/Private.app"
            ),
            .appDenied
        )
        XCTAssertEqual(
            engine.mutationDenialReason(
                bundleId: "com.example.private",
                displayName: "Private",
                path: "/Applications/Private.app"
            ),
            .appDenied
        )
    }

    func testDenylistMatchesDisplayNameCaseInsensitively() {
        let engine = PolicyEngine(appDenylist: ["private notes"])

        XCTAssertTrue(engine.isAppDenied(
            bundleId: "com.example.notes",
            displayName: "Private Notes",
            path: nil
        ))
    }

    func testDenylistMatchesFullPath() {
        let path = "/Applications/Private.app"
        let engine = PolicyEngine(appDenylist: [path])

        XCTAssertTrue(engine.isAppDenied(bundleId: nil, displayName: nil, path: path))
    }

    func testDenylistMatchesPathBasename() {
        let engine = PolicyEngine(appDenylist: ["private.app"])

        XCTAssertTrue(engine.isAppDenied(
            bundleId: "com.example.private",
            displayName: "Something Else",
            path: "/Applications/Private.app"
        ))
    }

    func testDenylistUsesExactTokensRatherThanSubstrings() {
        let engine = PolicyEngine(appDenylist: ["terminal"])

        XCTAssertFalse(engine.isAppDenied(
            bundleId: "com.example.terminal-helper",
            displayName: "Terminal Helper",
            path: "/Applications/Terminal Helper.app"
        ))
    }

    func testExplicitAppDenylistDoesNotMergeBuiltIns() {
        let engine = PolicyEngine(appDenylist: ["com.example.private"])

        XCTAssertTrue(engine.isAppDenied(bundleId: "com.example.private", displayName: nil, path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: "com.1password.1password", displayName: nil, path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: nil, displayName: "Bitwarden", path: nil))
        XCTAssertEqual(engine.appDenylist, ["com.example.private"])
    }

    func testExplicitEmptyAppDenylistDeniesNothing() {
        let engine = PolicyEngine(appDenylist: [])

        XCTAssertTrue(engine.appDenylist.isEmpty)
        XCTAssertFalse(engine.isAppDenied(
            bundleId: "com.1password.1password",
            displayName: "1Password",
            path: "/Applications/1Password.app"
        ))
        XCTAssertNil(engine.readDenialReason(
            bundleId: "com.bitwarden.desktop",
            displayName: "Bitwarden",
            path: nil
        ))
        XCTAssertNil(engine.mutationDenialReason(
            bundleId: "com.bitwarden.desktop",
            displayName: "Bitwarden",
            path: nil
        ))
    }

    // MARK: - Environment parsing

    func testEnvironmentDenylistIsCommaSeparatedTrimmedAndCaseInsensitive() {
        let parsed = PolicyEngine.appDenylistFrom(environment: [
            "SEMANTOUCH_DENIED_APPS": " com.example.One,Two App, /Applications/Three.app ,,\n"
        ])

        XCTAssertEqual(parsed, ["com.example.one", "two app", "/applications/three.app"])
    }

    func testMissingOrEmptyEnvironmentDenylistDeniesNothing() {
        XCTAssertEqual(PolicyEngine.appDenylistFrom(environment: [:]), [])
        XCTAssertEqual(
            PolicyEngine.appDenylistFrom(environment: ["SEMANTOUCH_DENIED_APPS": " , \n ,"]),
            []
        )
    }

    // MARK: - System policy composition

    func testSystemPolicyAugmentsBuiltInsWithOperatorDenylist() {
        let engine = PolicyEngine.system(environment: [
            "SEMANTOUCH_DENIED_APPS": "com.example.private"
        ])

        XCTAssertTrue(engine.isAppDenied(bundleId: "com.example.private", displayName: nil, path: nil))
        XCTAssertTrue(engine.isAppDenied(bundleId: "com.1password.1password", displayName: nil, path: nil))
        XCTAssertTrue(engine.isAppDenied(bundleId: nil, displayName: "NordPass", path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: "com.example.other", displayName: nil, path: nil))
    }

    func testSystemPolicyWithoutOperatorStillDeniesSensitiveApps() {
        let engine = PolicyEngine.system(environment: [:])

        for app in Self.sensitiveApps {
            XCTAssertTrue(
                engine.isAppDenied(bundleId: app.bundleId, displayName: app.displayName, path: app.path),
                "\(app.displayName) should be denied by default system policy"
            )
            XCTAssertEqual(
                engine.readDenialReason(bundleId: app.bundleId, displayName: nil, path: nil),
                .appDenied
            )
            XCTAssertEqual(
                engine.mutationDenialReason(bundleId: app.bundleId, displayName: nil, path: nil),
                .appDenied
            )
        }
    }

    func testSystemPolicySensitiveOverrideDisablesBuiltInsOnlyWithExactOne() {
        let engine = PolicyEngine.system(environment: [
            "SEMANTOUCH_ALLOW_SENSITIVE_APPS": "1"
        ])

        for app in Self.sensitiveApps {
            XCTAssertFalse(
                engine.isAppDenied(bundleId: app.bundleId, displayName: app.displayName, path: app.path),
                "\(app.displayName) must be allowed when SEMANTOUCH_ALLOW_SENSITIVE_APPS=1"
            )
            XCTAssertNil(engine.readDenialReason(bundleId: app.bundleId, displayName: nil, path: nil))
            XCTAssertNil(engine.mutationDenialReason(bundleId: app.bundleId, displayName: nil, path: nil))
        }
    }

    func testSystemPolicyMalformedSensitiveOverrideIsIgnored() {
        let malformedValues = ["true", "yes", "TRUE", "0", "1 ", " 1", "on", ""]

        for value in malformedValues {
            let engine = PolicyEngine.system(environment: [
                "SEMANTOUCH_ALLOW_SENSITIVE_APPS": value
            ])
            XCTAssertTrue(
                engine.isAppDenied(bundleId: "com.1password.1password", displayName: nil, path: nil),
                "malformed override \(value.debugDescription) must keep built-ins"
            )
            XCTAssertFalse(PolicyEngine.allowsSensitiveApps(environment: [
                "SEMANTOUCH_ALLOW_SENSITIVE_APPS": value
            ]))
        }
        XCTAssertTrue(PolicyEngine.allowsSensitiveApps(environment: [
            "SEMANTOUCH_ALLOW_SENSITIVE_APPS": "1"
        ]))
    }

    func testSystemPolicyOperatorDeniesSurviveSensitiveOverride() {
        let engine = PolicyEngine.system(environment: [
            "SEMANTOUCH_ALLOW_SENSITIVE_APPS": "1",
            "SEMANTOUCH_DENIED_APPS": "com.example.private,Terminal"
        ])

        XCTAssertTrue(engine.isAppDenied(bundleId: "com.example.private", displayName: nil, path: nil))
        XCTAssertTrue(engine.isAppDenied(bundleId: nil, displayName: "Terminal", path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: "com.1password.1password", displayName: nil, path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: nil, displayName: "Bitwarden", path: nil))
    }

    func testSystemPolicyReadAndMutationParityWithOperatorAndBuiltIns() {
        let engine = PolicyEngine.system(environment: [
            "SEMANTOUCH_DENIED_APPS": "com.example.private"
        ])

        let samples: [(String?, String?, String?)] = [
            ("com.example.private", "Private", "/Applications/Private.app"),
            ("com.1password.1password", "1Password", "/Applications/1Password.app"),
            ("me.proton.pass.electron", "Proton Pass", "/Applications/Proton Pass.app"),
        ]

        for (bundleId, displayName, path) in samples {
            XCTAssertEqual(
                engine.readDenialReason(bundleId: bundleId, displayName: displayName, path: path),
                .appDenied
            )
            XCTAssertEqual(
                engine.mutationDenialReason(bundleId: bundleId, displayName: displayName, path: path),
                .appDenied
            )
        }
    }

    func testDirectInitializerCompatibilityUsesExactExplicitDenylist() {
        let custom = PolicyEngine(
            defaultInterference: .allowBriefFocus,
            appDenylist: ["Com.Example.Custom", "Custom App"]
        )

        XCTAssertEqual(custom.defaultInterference, .allowBriefFocus)
        XCTAssertEqual(custom.appDenylist, ["com.example.custom", "custom app"])
        XCTAssertTrue(custom.isAppDenied(bundleId: "com.example.custom", displayName: nil, path: nil))
        XCTAssertTrue(custom.isAppDenied(bundleId: nil, displayName: "Custom App", path: nil))
        XCTAssertFalse(custom.isAppDenied(bundleId: "com.1password.1password", displayName: nil, path: nil))
    }
}
