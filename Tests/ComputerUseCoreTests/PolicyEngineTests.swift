import Foundation
import XCTest
@testable import ComputerUseCore

final class PolicyEngineTests: XCTestCase {
    // MARK: - Permissive default

    func testDefaultPolicyPermitsAnyObservedApp() {
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

    func testSystemPolicyUsesOnlyConfiguredDenylist() {
        let engine = PolicyEngine.system(environment: [
            "SEMANTOUCH_DENIED_APPS": "com.example.private"
        ])

        XCTAssertTrue(engine.isAppDenied(bundleId: "com.example.private", displayName: nil, path: nil))
        XCTAssertFalse(engine.isAppDenied(bundleId: "com.example.other", displayName: nil, path: nil))
    }
}
