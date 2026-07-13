import XCTest
@testable import ComputerUseCore

/// In-memory `AppEnvironment` for deterministic, permission-free resolution tests.
private struct MockAppEnvironment: AppEnvironment {
    var records: [AppRecord]
    var existingPaths: Set<String>

    func allApps() -> [AppRecord] { records }
    func app(forPID pid: Int32) -> AppRecord? { records.first { $0.pid == pid } }
    func pathExists(_ path: String) -> Bool { existingPaths.contains(path) }
}

final class AppResolverTests: XCTestCase {
    private func makeResolver() -> AppResolver {
        let records: [AppRecord] = [
            AppRecord(bundleId: "com.apple.Safari", displayName: "Safari",
                      path: "/Applications/Safari.app", pid: 100, isRunning: true, windows: 2),
            AppRecord(bundleId: "com.apple.Notes", displayName: "Notes",
                      path: "/System/Applications/Notes.app", pid: nil, isRunning: false, windows: 0),
            AppRecord(bundleId: "com.apple.TextEdit", displayName: "TextEdit",
                      path: "/System/Applications/TextEdit.app", pid: 200, isRunning: true, windows: 1),
            // Two apps sharing an exact display name, to exercise ambiguity.
            AppRecord(bundleId: "com.a.player", displayName: "Player",
                      path: "/Applications/Player A.app", pid: 300, isRunning: true, windows: 1),
            AppRecord(bundleId: "com.b.player", displayName: "Player",
                      path: "/Applications/Player B.app", pid: 301, isRunning: true, windows: 1),
        ]
        let env = MockAppEnvironment(
            records: records,
            existingPaths: [
                "/Applications/Safari.app",
                "/System/Applications/Notes.app",
                "/System/Applications/TextEdit.app",
            ]
        )
        return AppResolver(environment: env)
    }

    private func resolvedRecord(_ result: Result<AppRecord, CUError>) -> AppRecord? {
        if case let .success(record) = result { return record }
        return nil
    }

    private func resolvedError(_ result: Result<AppRecord, CUError>) -> CUError? {
        if case let .failure(error) = result { return error }
        return nil
    }

    // Rule 0 — pid:<n>.
    func testResolvesByPID() {
        let result = makeResolver().resolve("pid:200")
        XCTAssertEqual(resolvedRecord(result)?.bundleId, "com.apple.TextEdit")
    }

    func testUnknownPIDIsNotFound() {
        let result = makeResolver().resolve("pid:999")
        XCTAssertEqual(resolvedError(result)?.code, .appNotFound)
    }

    // Rule 1 — exact bundle id, case-insensitive.
    func testResolvesByBundleIdCaseInsensitively() {
        let result = makeResolver().resolve("COM.APPLE.SAFARI")
        XCTAssertEqual(resolvedRecord(result)?.bundleId, "com.apple.Safari")
    }

    // Rule 2 — exact absolute .app path that exists.
    func testResolvesByExistingPath() {
        let result = makeResolver().resolve("/System/Applications/Notes.app")
        XCTAssertEqual(resolvedRecord(result)?.bundleId, "com.apple.Notes")
    }

    func testPathThatDoesNotExistFallsThroughToNotFound() {
        // Well-formed path, not on disk, and not a display name → app_not_found.
        let result = makeResolver().resolve("/Applications/Ghost.app")
        XCTAssertEqual(resolvedError(result)?.code, .appNotFound)
    }

    // Rule 3 — exact localized display name.
    func testResolvesByExactDisplayName() {
        let result = makeResolver().resolve("TextEdit")
        XCTAssertEqual(resolvedRecord(result)?.bundleId, "com.apple.TextEdit")
    }

    // Rule 4 — unique case-insensitive display-name match.
    func testResolvesByCaseInsensitiveDisplayName() {
        let result = makeResolver().resolve("safari")
        XCTAssertEqual(resolvedRecord(result)?.bundleId, "com.apple.Safari")
    }

    // Ambiguity — two apps share the exact display name.
    func testAmbiguousDisplayNameReturnsCandidates() {
        let result = makeResolver().resolve("Player")
        guard case let .failure(error) = result else {
            return XCTFail("expected ambiguous_app failure")
        }
        XCTAssertEqual(error.code, .ambiguousApp)
        guard case let .ambiguousApp(query, candidates) = error else {
            return XCTFail("expected ambiguousApp payload")
        }
        XCTAssertEqual(query, "Player")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.id)), ["com.a.player", "com.b.player"])
    }

    // Nothing matches.
    func testUnknownQueryIsNotFound() {
        let result = makeResolver().resolve("Nonexistent Application")
        guard case let .failure(error) = result, case let .appNotFound(query) = error else {
            return XCTFail("expected app_not_found")
        }
        XCTAssertEqual(query, "Nonexistent Application")
    }

    // Precedence — bundle id wins even when a display-name match also exists.
    func testBundleIdRulePrecedesNameRule() {
        // "com.apple.Notes" is a bundle id (rule 1); it must not be treated as a name.
        let result = makeResolver().resolve("com.apple.Notes")
        XCTAssertEqual(resolvedRecord(result)?.displayName, "Notes")
    }

    // toSummary id fallback: no bundle id → path.
    func testSummaryIdFallsBackToPath() {
        let record = AppRecord(bundleId: nil, displayName: "Custom",
                               path: "/Applications/Custom.app", pid: nil, isRunning: false, windows: 0)
        XCTAssertEqual(record.toSummary().id, "/Applications/Custom.app")
    }
}
