import CryptoKit
import Foundation
import XCTest
import ComputerUseCore
@testable import ComputerUseService
@testable import SemantouchCLIKit

final class UpdateServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: - Semantic version

    func testSemanticVersionOrderingMatchesReleasePrecedence() throws {
        XCTAssertLessThan(try SemanticVersion("0.2.0"), try SemanticVersion("0.3.0"))
        XCTAssertLessThan(try SemanticVersion("v1.0.0-beta.2"), try SemanticVersion("1.0.0-beta.10"))
        XCTAssertLessThan(try SemanticVersion("1.0.0-rc.1"), try SemanticVersion("1.0.0"))
        XCTAssertEqual(try SemanticVersion("1.2.3+build.9"), try SemanticVersion("v1.2.3"))
        XCTAssertThrowsError(try SemanticVersion("1.0"))
        XCTAssertThrowsError(try SemanticVersion("1.0.0-alpha.01"))
        XCTAssertThrowsError(try SemanticVersion("1.0.0+"))
        XCTAssertThrowsError(try SemanticVersion("1.0.0+build..9"))
    }

    // MARK: - Asset names

    func testAppZipAssetNamesAreVersionedUniversal2() {
        XCTAssertEqual(
            Packaging.appZipAssetName(forVersion: "0.3.0"),
            "Semantouch-v0.3.0-macos-universal2.zip"
        )
        XCTAssertEqual(
            Packaging.appZipChecksumAssetName(forVersion: "0.3.0"),
            "Semantouch-v0.3.0-macos-universal2.zip.sha256"
        )
    }

    // MARK: - check()

    func testCheckReportsAvailableRelease() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        let service = makeService(releaseURL: fixture.releaseURL)

        let check = await service.check(currentVersion: "0.2.0")

        XCTAssertEqual(
            check,
            UpdateCheck(
                currentVersion: "0.2.0",
                latestVersion: "0.3.0",
                status: .available
            )
        )
    }

    func testCheckTreatsNewerLocalBuildAsUpToDate() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        let service = makeService(releaseURL: fixture.releaseURL)

        let check = await service.check(currentVersion: "0.4.0")

        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.latestVersion, "0.3.0")
    }

    func testCheckReportsUnknownWithoutFailingDoctorWhenGitHubIsUnavailable() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        StubURLProtocol.register(status: 503, data: Data(), for: fixture.releaseURL)
        let service = makeService(releaseURL: fixture.releaseURL)

        let check = await service.check(currentVersion: "0.2.0")

        XCTAssertEqual(check.status, .unknown)
        XCTAssertNil(check.latestVersion)
        XCTAssertEqual(check.message, "GitHub returned HTTP status 503")
    }

    // MARK: - Successful whole-bundle update

    func testInstallLatestReplacesWholeAppBundle() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("install-success")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let originalHost = try Data(contentsOf: destination.appendingPathComponent(Packaging.hostRelativePath))

        let service = makeService(releaseURL: fixture.releaseURL)
        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            appBundleURL: destination
        )

        XCTAssertEqual(result.previousVersion, "0.2.0")
        XCTAssertEqual(result.version, "0.3.0")
        XCTAssertEqual(result.path, destination.path)
        XCTAssertTrue(result.updated)
        XCTAssertFalse(result.deferred)

        let info = try readPlist(at: destination)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.3.0")
        let newHost = try Data(contentsOf: destination.appendingPathComponent(Packaging.hostRelativePath))
        XCTAssertNotEqual(originalHost, newHost)
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: destination.appendingPathComponent(Packaging.relayRelativePath).path
        ))
    }

    func testInstallLatestDoesNotDownloadAssetsWhenAlreadyCurrent() async throws {
        let fixture = makeFixture(tag: "v0.2.0")
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        let service = makeService(releaseURL: fixture.releaseURL)

        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            appBundleURL: URL(fileURLWithPath: "/Applications/Semantouch.app")
        )

        XCTAssertFalse(result.updated)
        XCTAssertEqual(result.version, "0.2.0")
        XCTAssertFalse(result.deferred)
    }

    // MARK: - Checksum / tamper

    func testInstallLatestLeavesAppUntouchedOnChecksumMismatch() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: String(repeating: "0", count: 64))

        let root = uniqueTempDir("checksum-mismatch")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = makeService(releaseURL: fixture.releaseURL)
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected checksum mismatch")
        } catch {
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    // MARK: - Extraction shape

    func testInstallLatestRejectsWrongExtractionShape() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        // ZIP with two top-level entries.
        let zip = try makeZip(entries: [
            ("Semantouch.app/Contents/Info.plist", Data()),
            ("README.txt", Data("nope".utf8)),
        ])
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("bad-shape")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = makeService(releaseURL: fixture.releaseURL)
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected invalid extraction shape")
        } catch let error as UpdateError {
            guard case .invalidExtractionShape = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    // MARK: - Bundle validation rejections

    func testVerifyAppBundleRejectsWrongBundleId() throws {
        let root = uniqueTempDir("bad-bundle-id")
        let app = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: app, version: "0.3.0", bundleId: "com.example.wrong")

        XCTAssertThrowsError(try UpdateService.verifyAppBundleLayout(at: app, expectedVersion: "0.3.0")) { error in
            guard case let UpdateError.invalidBundle(reason) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(reason.contains("CFBundleIdentifier"))
        }
    }

    func testVerifyAppBundleRejectsWrongHostExecutable() throws {
        let root = uniqueTempDir("bad-host")
        let app = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: app, version: "0.3.0", hostName: "WrongHost")

        XCTAssertThrowsError(try UpdateService.verifyAppBundleLayout(at: app, expectedVersion: "0.3.0")) { error in
            guard case let UpdateError.invalidBundle(reason) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(
                reason.contains("CFBundleExecutable") || reason.contains("host executable"),
                reason
            )
        }
    }

    func testVerifyAppBundleRejectsMissingRelay() throws {
        let root = uniqueTempDir("missing-relay")
        let app = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: app, version: "0.3.0", includeRelay: false)

        XCTAssertThrowsError(try UpdateService.verifyAppBundleLayout(at: app, expectedVersion: "0.3.0")) { error in
            guard case let UpdateError.invalidBundle(reason) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(reason.contains("relay"), reason)
        }
    }

    func testVerifyAppBundleRejectsVersionMismatch() throws {
        let root = uniqueTempDir("version-mismatch")
        let app = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: app, version: "0.2.5")

        XCTAssertThrowsError(try UpdateService.verifyAppBundleLayout(at: app, expectedVersion: "0.3.0")) { error in
            XCTAssertEqual(
                error as? UpdateError,
                .downloadedVersionMismatch(expected: "0.3.0", actual: "0.2.5")
            )
        }
    }

    func testInstallLatestLeavesAppUntouchedOnSignatureFailure() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("sig-fail")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = UpdateService(
            session: makeSession(),
            releaseURL: fixture.releaseURL,
            signatureValidator: { _ in throw UpdateError.invalidSignature("publisher mismatch") },
            notarizationValidator: { _ in }
        )
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected signature failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .invalidSignature("publisher mismatch"))
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    func testInstallLatestLeavesAppUntouchedOnNotarizationFailure() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("notarization-fail")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = UpdateService(
            session: makeSession(),
            releaseURL: fixture.releaseURL,
            signatureValidator: { _ in },
            notarizationValidator: { _ in throw UpdateError.notarizationFailed("gatekeeper rejected") }
        )
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected notarization failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notarizationFailed("gatekeeper rejected"))
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    func testInstallLatestLeavesAppUntouchedWhenAssetReportsWrongVersion() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        // Archive claims 0.2.5 while release tag is 0.3.0.
        let zip = try makeAppZip(version: "0.2.5")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("asset-version")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = makeService(releaseURL: fixture.releaseURL)
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected version mismatch")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .downloadedVersionMismatch(expected: "0.3.0", actual: "0.2.5")
            )
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    // MARK: - Team identity (via injectable signature validator surface)

    func testSignatureValidatorReceivesStagedAppPath() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("team-path")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")

        final class Box: @unchecked Sendable {
            var leaf: String?
        }
        let box = Box()
        let service = UpdateService(
            session: makeSession(),
            releaseURL: fixture.releaseURL,
            signatureValidator: { url in
                box.leaf = url.lastPathComponent
                XCTAssertEqual(url.lastPathComponent, Packaging.appBundleName)
            },
            notarizationValidator: { _ in }
        )
        _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
        XCTAssertEqual(box.leaf, Packaging.appBundleName)
    }

    // MARK: - Downgrade

    func testStaleUpdaterDoesNotReplaceNewerInstalledApp() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("no-downgrade")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.4.0")
        let original = try snapshotApp(destination)

        let service = makeService(releaseURL: fixture.releaseURL)
        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            appBundleURL: destination
        )

        XCTAssertFalse(result.updated)
        XCTAssertEqual(result.version, "0.4.0")
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    func testStageLatestRefusesExplicitDowngrade() async throws {
        let fixture = makeFixture(tag: "v0.2.0")
        let zip = try makeAppZip(version: "0.2.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let service = makeService(releaseURL: fixture.releaseURL)
        do {
            _ = try await service.stageLatest(currentVersion: "0.3.0")
            XCTFail("expected downgrade refusal")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .downgradeRefused(current: "0.3.0", candidate: "0.2.0")
            )
        }
    }

    // MARK: - Nested executable refusal

    func testInstallLatestRefusesNestedExecutablePath() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let service = makeService(releaseURL: fixture.releaseURL)
        let nested = URL(fileURLWithPath: "/Applications/Semantouch.app/Contents/MacOS/SemantouchHost")
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: nested)
            XCTFail("expected nested refusal")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .nestedExecutableReplacementRefused(path: nested.path)
            )
        }
    }

    // MARK: - Canonical installs / duplicates / user install

    func testDiscoverCanonicalInstallsPrefersSystemThenUser() throws {
        let home = uniqueTempDir("home-discover")
        let systemRoot = uniqueTempDir("system-apps")
        // Simulate by writing only the user path under a fake home; system path
        // discovery uses the real Packaging.systemAppPath which may or may not
        // exist. We only assert the pure shape of CanonicalAppInstalls here.
        let installs = CanonicalAppInstalls(
            systemApp: URL(fileURLWithPath: "/Applications/Semantouch.app"),
            userApp: home.appendingPathComponent("Applications/Semantouch.app")
        )
        XCTAssertTrue(installs.hasDuplicates)
        XCTAssertEqual(installs.preferred, URL(fileURLWithPath: "/Applications/Semantouch.app"))

        let userOnly = CanonicalAppInstalls(
            systemApp: nil,
            userApp: home.appendingPathComponent("Applications/Semantouch.app")
        )
        XCTAssertFalse(userOnly.hasDuplicates)
        XCTAssertEqual(userOnly.preferred, userOnly.userApp)
        _ = systemRoot
    }

    func testPreferredInstallDestinationChoosesWritableUserPath() throws {
        // Isolate from the host machine: this environment's real /Applications is
        // writable, so without injection the system path would correctly win.
        // Inject an unwritable system root and a private home with Applications.
        let home = uniqueTempDir("home-pref")
        let apps = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

        let systemRoot = uniqueTempDir("system-pref")
        // Create a non-writable system Applications parent so the system path loses.
        let systemApps = systemRoot.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: systemApps, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: systemApps.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: systemApps.path
            )
        }
        let injectedSystemApp = systemApps.appendingPathComponent(Packaging.appBundleName)

        let service = UpdateService(
            session: makeSession(),
            releaseURL: URL(string: "https://fixtures.invalid/unused")!,
            homeDirectory: { home.path },
            systemAppPath: { injectedSystemApp.path }
        )
        let destination = try service.preferredInstallDestination()
        XCTAssertEqual(destination.lastPathComponent, Packaging.appBundleName)
        XCTAssertEqual(
            destination.path,
            home.appendingPathComponent("Applications/\(Packaging.appBundleName)").path
        )
    }

    func testInstallLatestCanBootstrapUserInstall() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let home = uniqueTempDir("user-bootstrap")
        let destination = home
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Semantouch.app")
        // Parent must exist and be writable; app itself does not exist yet.
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let service = makeService(releaseURL: fixture.releaseURL)
        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            appBundleURL: destination
        )

        XCTAssertTrue(result.updated)
        XCTAssertEqual(result.version, "0.3.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let info = try readPlist(at: destination)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.3.0")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: destination.appendingPathComponent(Packaging.relayRelativePath).path
        ))
    }

    // MARK: - Same-volume atomic upgrade + rollback

    func testApplyStagedUpdateIsSameVolumeAtomic() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("atomic")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")

        let service = makeService(releaseURL: fixture.releaseURL)
        let staged = try await service.stageLatest(currentVersion: "0.2.0")
        defer { try? FileManager.default.removeItem(at: staged.stagingRootURL) }

        try service.applyStagedUpdate(staged, to: destination)

        let info = try readPlist(at: destination)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.3.0")
        // No leftover backup/incoming siblings.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(siblings.contains(where: { $0.hasPrefix(".Semantouch.app.backup-") }))
        XCTAssertFalse(siblings.contains(where: { $0.hasPrefix(".Semantouch.app.incoming-") }))
    }

    func testApplyStagedUpdateRollsBackOnPostApplyVerificationFailure() async throws {
        let root = uniqueTempDir("rollback")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        // Stage a valid 0.3.0 bundle manually.
        let stagingRoot = root.appendingPathComponent("stage", isDirectory: true)
        let stagedApp = stagingRoot.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: stagedApp, version: "0.3.0")
        let staged = StagedAppUpdate(
            version: "0.3.0",
            stagedAppURL: stagedApp,
            stagingRootURL: stagingRoot,
            zipChecksum: "deadbeef"
        )

        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let counter = Counter()
        let service = UpdateService(
            session: makeSession(),
            releaseURL: URL(string: "https://fixtures.invalid/unused")!,
            signatureValidator: { _ in
                counter.value += 1
                // First call is pre-apply (staged); second is post-apply (destination).
                if counter.value >= 2 {
                    throw UpdateError.invalidSignature("post-apply failure")
                }
            },
            notarizationValidator: { _ in }
        )

        do {
            try service.applyStagedUpdate(staged, to: destination)
            XCTFail("expected post-apply failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .invalidSignature("post-apply failure"))
        }
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    // MARK: - Readiness-deferred replacement seam

    func testInstallLatestDefersWhenNotReadyToReplace() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let zip = try makeAppZip(version: "0.3.0")
        registerRelease(fixture, zip: zip, checksum: sha256(zip))

        let root = uniqueTempDir("deferred")
        let destination = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")
        let original = try snapshotApp(destination)

        let service = makeService(releaseURL: fixture.releaseURL)
        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            appBundleURL: destination,
            isReadyToReplace: { false }
        )

        XCTAssertFalse(result.updated)
        XCTAssertTrue(result.deferred)
        XCTAssertEqual(result.version, "0.3.0")
        XCTAssertEqual(try snapshotApp(destination), original)
    }

    // MARK: - Unwritable system app

    func testInstallLatestRefusesUnwritableSystemApp() async throws {
        // Use a path under a non-writable parent simulation: create a directory
        // without write permission for the process.
        let root = uniqueTempDir("unwritable")
        let lockedParent = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedParent, withIntermediateDirectories: true)
        let destination = lockedParent.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: destination, version: "0.2.0")

        // Drop write on the parent so replacement cannot proceed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: lockedParent.path
        )
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: lockedParent.path
            )
        }

        let fixture = makeFixture(tag: "v0.3.0")
        // No need to register ZIP — refusal happens before download when destination unwritable.
        let service = makeService(releaseURL: fixture.releaseURL)
        do {
            _ = try await service.installLatest(currentVersion: "0.2.0", appBundleURL: destination)
            XCTFail("expected destination not writable")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .destinationNotWritable(path: destination.path)
            )
        }
    }

    // MARK: - Helpers

    private func makeService(releaseURL: URL) -> UpdateService {
        UpdateService(
            session: makeSession(),
            releaseURL: releaseURL,
            signatureValidator: { _ in },
            notarizationValidator: { _ in }
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeFixture(tag: String) -> ReleaseFixture {
        let id = UUID().uuidString
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let zipName = Packaging.appZipAssetName(forVersion: version)
        let checksumName = Packaging.appZipChecksumAssetName(forVersion: version)
        let releaseURL = URL(string: "https://fixtures.invalid/\(id)/latest")!
        let zipURL = URL(string: "https://fixtures.invalid/\(id)/\(zipName)")!
        let checksumURL = URL(string: "https://fixtures.invalid/\(id)/\(checksumName)")!
        let payload: [String: Any] = [
            "tag_name": tag,
            "assets": [
                ["name": zipName, "browser_download_url": zipURL.absoluteString],
                ["name": checksumName, "browser_download_url": checksumURL.absoluteString],
            ],
        ]
        return ReleaseFixture(
            releaseURL: releaseURL,
            zipURL: zipURL,
            checksumURL: checksumURL,
            zipName: zipName,
            releaseData: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private func registerRelease(_ fixture: ReleaseFixture, zip: Data, checksum: String) {
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        StubURLProtocol.register(status: 200, data: zip, for: fixture.zipURL)
        StubURLProtocol.register(
            status: 200,
            data: Data("\(checksum)  \(fixture.zipName)\n".utf8),
            for: fixture.checksumURL
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uniqueTempDir(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-\(label)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeAppBundle(
        at appURL: URL,
        version: String,
        bundleId: String = Packaging.bundleId,
        hostName: String = Packaging.hostExecutableName,
        includeRelay: Bool = true
    ) throws {
        let fm = FileManager.default
        let macos = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleExecutable": hostName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSMinimumSystemVersion": Packaging.minimumMacOS,
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        let hostBody = Data("#!/bin/sh\nprintf 'host \(version)\\n'\n".utf8)
        let hostPath = macos.appendingPathComponent(hostName)
        try hostBody.write(to: hostPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostPath.path)

        if includeRelay {
            let relayBody = Data("#!/bin/sh\nprintf 'relay \(version)\\n'\n".utf8)
            let relayPath = macos.appendingPathComponent(Packaging.relayExecutableName)
            try relayBody.write(to: relayPath)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relayPath.path)
        }
    }

    private func makeAppZip(version: String) throws -> Data {
        let root = uniqueTempDir("zip-\(version)")
        let app = root.appendingPathComponent("Semantouch.app")
        try writeAppBundle(at: app, version: version)
        let zipURL = root.appendingPathComponent(Packaging.appZipAssetName(forVersion: version))
        try runDittoZip(source: app, zipURL: zipURL)
        return try Data(contentsOf: zipURL)
    }

    private func makeZip(entries: [(String, Data)]) throws -> Data {
        let root = uniqueTempDir("custom-zip")
        for (relative, data) in entries {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        // Zip the contents of root so top-level entries match `entries`.
        let zipURL = root.deletingLastPathComponent()
            .appendingPathComponent("custom-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", root.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: zipURL)
    }

    private func runDittoZip(source: URL, zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpdateServiceTests", code: Int(process.terminationStatus))
        }
    }

    private func readPlist(at appURL: URL) throws -> [String: Any] {
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: info)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func snapshotApp(_ appURL: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: appURL, includingPropertiesForKeys: nil) else {
            return result
        }
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                let relative = fileURL.path.replacingOccurrences(of: appURL.path + "/", with: "")
                result[relative] = try Data(contentsOf: fileURL)
            }
        }
        return result
    }
}

private struct ReleaseFixture {
    var releaseURL: URL
    var zipURL: URL
    var checksumURL: URL
    var zipName: String
    var releaseData: Data
}

private final class StubURLProtocol: URLProtocol {
    private struct Stub {
        var status: Int
        var data: Data
    }

    private static let lock = NSLock()
    private static var stubs: [URL: Stub] = [:]

    static func register(status: Int, data: Data, for url: URL) {
        lock.lock()
        stubs[url] = Stub(status: status, data: data)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        stubs.removeAll()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        let stub = Self.stubs[url]
        Self.lock.unlock()
        guard let stub,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/octet-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
