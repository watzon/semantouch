import CryptoKit
import Darwin
import Foundation
import Security
import ComputerUseCore
import MCPServer
import SemantouchCLIKit

public enum UpdateAvailability: String, Codable, Equatable, Sendable {
    case available
    case upToDate = "up_to_date"
    case unknown
}

public struct UpdateCheck: Codable, Equatable, Sendable {
    public var currentVersion: String
    public var latestVersion: String?
    public var status: UpdateAvailability
    public var message: String?

    public init(
        currentVersion: String,
        latestVersion: String?,
        status: UpdateAvailability,
        message: String? = nil
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.status = status
        self.message = message
    }
}

public struct DoctorCommandReport: Codable, Equatable, Sendable {
    public var helper: DoctorResult.HelperInfo
    public var accessibility: PermissionStatus
    public var screenRecording: PermissionStatus
    public var ready: Bool
    public var remediation: [String]
    public var update: UpdateCheck

    public init(doctor: DoctorResult, update: UpdateCheck) {
        helper = doctor.helper
        accessibility = doctor.accessibility
        screenRecording = doctor.screenRecording
        ready = doctor.ready
        remediation = doctor.remediation
        self.update = update
    }
}

/// Result of a whole-app install/replace attempt.
///
/// `path` is always the selected `Semantouch.app` bundle path — never a nested
/// Mach-O. `deferred` is true when staging/verification succeeded but the
/// readiness callback declined immediate replacement.
public struct UpdateInstallResult: Codable, Equatable, Sendable {
    public var previousVersion: String
    public var version: String
    public var path: String
    public var updated: Bool
    public var deferred: Bool

    public init(
        previousVersion: String,
        version: String,
        path: String,
        updated: Bool,
        deferred: Bool = false
    ) {
        self.previousVersion = previousVersion
        self.version = version
        self.path = path
        self.updated = updated
        self.deferred = deferred
    }
}

/// Discovery result for the two canonical install locations.
public struct CanonicalAppInstalls: Equatable, Sendable {
    public var systemApp: URL?
    public var userApp: URL?
    public var hasDuplicates: Bool
    public var preferred: URL?

    public init(systemApp: URL?, userApp: URL?) {
        self.systemApp = systemApp
        self.userApp = userApp
        self.hasDuplicates = systemApp != nil && userApp != nil
        self.preferred = systemApp ?? userApp
    }
}

/// A verified, staged app bundle ready for same-volume replacement.
public struct StagedAppUpdate: Equatable, Sendable {
    public var version: String
    public var stagedAppURL: URL
    public var stagingRootURL: URL
    public var zipChecksum: String

    public init(version: String, stagedAppURL: URL, stagingRootURL: URL, zipChecksum: String) {
        self.version = version
        self.stagedAppURL = stagedAppURL
        self.stagingRootURL = stagingRootURL
        self.zipChecksum = zipChecksum
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidVersion(String)
    case missingAsset(String)
    case invalidChecksum
    case checksumMismatch
    case invalidSignature(String)
    case notarizationFailed(String)
    case unsupportedArchitecture
    case invalidExtractionShape(String)
    case invalidBundle(String)
    case downloadedVersionMismatch(expected: String, actual: String?)
    case downgradeRefused(current: String, candidate: String)
    case destinationNotWritable(path: String)
    case nestedExecutableReplacementRefused(path: String)
    case crossVolumeReplacement(path: String)
    case replacementFailed(path: String, reason: String)
    case replacementDeferred(path: String, version: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "GitHub returned an invalid HTTP response"
        case let .httpStatus(status):
            return "GitHub returned HTTP status \(status)"
        case let .invalidVersion(version):
            return "GitHub's latest release tag is not a semantic version: \(version)"
        case let .missingAsset(name):
            return "GitHub's latest release does not contain \(name)"
        case .invalidChecksum:
            return "the release checksum is not a valid SHA-256 digest"
        case .checksumMismatch:
            return "the downloaded release failed SHA-256 verification"
        case let .invalidSignature(reason):
            return "the downloaded release has an invalid publisher signature: \(reason)"
        case let .notarizationFailed(reason):
            return "the downloaded release failed notarization/Gatekeeper assessment: \(reason)"
        case .unsupportedArchitecture:
            return "released Semantouch app bundles currently support macOS arm64 and x86_64 (universal2) only"
        case let .invalidExtractionShape(reason):
            return "the downloaded app archive has an invalid layout: \(reason)"
        case let .invalidBundle(reason):
            return "the downloaded app bundle is invalid: \(reason)"
        case let .downloadedVersionMismatch(expected, actual):
            let found = actual.map { "v\($0)" } ?? "an unreadable version"
            return "the downloaded app reported \(found), expected v\(expected)"
        case let .downgradeRefused(current, candidate):
            return "refusing to downgrade Semantouch.app from v\(current) to v\(candidate)"
        case let .destinationNotWritable(path):
            return "cannot replace unwritable install at \(path); install to \(Packaging.userAppPath) or fix permissions"
        case let .nestedExecutableReplacementRefused(path):
            return "refusing to replace nested executable \(path); updates replace the whole Semantouch.app bundle only"
        case let .crossVolumeReplacement(path):
            return "cannot perform a same-volume staged rename onto \(path)"
        case let .replacementFailed(path, reason):
            return "could not replace \(path): \(reason)"
        case let .replacementDeferred(path, version):
            return "staged Semantouch.app v\(version) at \(path) but replacement is deferred until the host is ready"
        }
    }
}

/// Whole-app update/bootstrap service.
///
/// HostController should call:
/// - `check(currentVersion:)` for doctor/update availability
/// - `discoverCanonicalInstalls()` to choose `/Applications` then `~/Applications`
/// - `installLatest(currentVersion:appBundleURL:isReadyToReplace:)` for download → verify → same-volume replace
/// - `stageLatest(...)` / `verifyAppBundle(...)` / `applyStagedUpdate(...)` when it needs an explicit readiness seam
///
/// Production trust has no bypass. Nested Mach-Os are never replaced in isolation.
public struct UpdateService: @unchecked Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/watzon/semantouch/releases/latest")!

    private let session: URLSession
    private let releaseURL: URL
    private let fileManager: FileManager
    private let signatureValidator: @Sendable (URL) throws -> Void
    private let notarizationValidator: @Sendable (URL) throws -> Void
    private let homeDirectory: () -> String
    private let systemAppPath: () -> String

    public init(session: URLSession = .shared, releaseURL: URL = Self.latestReleaseURL) {
        self.session = session
        self.releaseURL = releaseURL
        self.fileManager = .default
        self.signatureValidator = { try Self.validateAppBundleSignature(at: $0) }
        self.notarizationValidator = { try Self.validateNotarization(at: $0) }
        self.homeDirectory = { NSHomeDirectory() }
        self.systemAppPath = { Packaging.systemAppPath }
    }

    /// Test/injection initializer. Signature and notarization validators default to no-ops
    /// so permission-free contract tests can exercise staging and replacement without
    /// real Developer ID material. `homeDirectory` / `systemAppPath` isolate install
    /// preference from the host machine's real `/Applications` and `~/Applications`.
    init(
        session: URLSession,
        releaseURL: URL,
        fileManager: FileManager = .default,
        homeDirectory: @escaping () -> String = { NSHomeDirectory() },
        systemAppPath: @escaping () -> String = { Packaging.systemAppPath },
        signatureValidator: @escaping @Sendable (URL) throws -> Void = { _ in },
        notarizationValidator: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.session = session
        self.releaseURL = releaseURL
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.systemAppPath = systemAppPath
        self.signatureValidator = signatureValidator
        self.notarizationValidator = notarizationValidator
    }

    // MARK: - Public API (HostController surface)

    public func check(currentVersion: String = MCPServer.serverVersion) async -> UpdateCheck {
        do {
            let release = try await latestRelease()
            let current = try SemanticVersion(currentVersion)
            let status: UpdateAvailability = release.version > current ? .available : .upToDate
            return UpdateCheck(
                currentVersion: currentVersion,
                latestVersion: release.version.description,
                status: status
            )
        } catch {
            return UpdateCheck(
                currentVersion: currentVersion,
                latestVersion: nil,
                status: .unknown,
                message: error.localizedDescription
            )
        }
    }

    /// Discover the two canonical install locations. Preference order is system
    /// (`/Applications/Semantouch.app`) then user (`~/Applications/Semantouch.app`).
    public func discoverCanonicalInstalls() -> CanonicalAppInstalls {
        let system = URL(fileURLWithPath: systemAppPath())
        let user = URL(fileURLWithPath: (homeDirectory() as NSString).appendingPathComponent("Applications/\(Packaging.appBundleName)"))
        return CanonicalAppInstalls(
            systemApp: fileManager.fileExists(atPath: system.path) ? system : nil,
            userApp: fileManager.fileExists(atPath: user.path) ? user : nil
        )
    }

    /// Preferred destination for a fresh install: system if writable, otherwise user.
    public func preferredInstallDestination() throws -> URL {
        let system = URL(fileURLWithPath: systemAppPath())
        if isWritableDestination(system) {
            return system
        }
        let user = URL(fileURLWithPath: (homeDirectory() as NSString).appendingPathComponent("Applications/\(Packaging.appBundleName)"))
        if isWritableDestination(user) {
            return user
        }
        throw UpdateError.destinationNotWritable(path: system.path)
    }

    /// Compatibility entry for callers that still resolve a nested executable path
    /// (legacy CLI). Locates the enclosing `Semantouch.app` and replaces the whole
    /// bundle — never the nested Mach-O itself. HostController should call
    /// `installLatest(appBundleURL:)` with `Bundle.main.bundleURL` instead.
    public func installLatest(
        currentVersion: String = MCPServer.serverVersion,
        executablePath: String
    ) async throws -> UpdateInstallResult {
        let appURL = try enclosingAppBundle(forExecutablePath: executablePath)
        return try await installLatest(
            currentVersion: currentVersion,
            appBundleURL: appURL
        )
    }

    /// Download, verify, and install/replace a whole `Semantouch.app`.
    ///
    /// - Parameters:
    ///   - currentVersion: running host version (reject downgrades).
    ///   - appBundleURL: selected `Semantouch.app` path (or desired destination for a fresh install).
    ///     Nested executable paths are refused.
    ///   - isReadyToReplace: readiness callback. Return `false` to keep the staged bundle
    ///     and defer the rename (active sessions / drain). Defaults to immediate apply.
    public func installLatest(
        currentVersion: String = MCPServer.serverVersion,
        appBundleURL: URL,
        isReadyToReplace: @Sendable () -> Bool = { true }
    ) async throws -> UpdateInstallResult {
        let destination = try resolveAppBundleDestination(appBundleURL)
        try refuseUnwritableSystemInstall(destination)

        let release = try await latestRelease()
        let current = try SemanticVersion(currentVersion)

        if let installed = try? installedBundleVersion(at: destination),
           let installedVersion = try? SemanticVersion(installed),
           installedVersion >= release.version {
            return UpdateInstallResult(
                previousVersion: currentVersion,
                version: installedVersion.description,
                path: destination.path,
                updated: false,
                deferred: false
            )
        }

        guard release.version > current else {
            if release.version < current {
                throw UpdateError.downgradeRefused(
                    current: current.description,
                    candidate: release.version.description
                )
            }
            return UpdateInstallResult(
                previousVersion: currentVersion,
                version: release.version.description,
                path: destination.path,
                updated: false,
                deferred: false
            )
        }

        #if !arch(arm64) && !arch(x86_64)
        throw UpdateError.unsupportedArchitecture
        #endif

        let staged = try await stageLatest(release: release, expectedMinimum: current)
        defer { try? fileManager.removeItem(at: staged.stagingRootURL) }

        if !isReadyToReplace() {
            // Leave the staging root for the host to apply after drain; do not delete.
            // Caller owns cleanup via the returned path only when deferred is false —
            // for deferred we re-stage on next attempt and clean here is intentional
            // only when apply succeeds. Report deferred without applying.
            // Keep staged files only if the host takes ownership; default cleans after return.
            // The readiness seam is the callback itself; HostController should drain then re-call.
            return UpdateInstallResult(
                previousVersion: currentVersion,
                version: staged.version,
                path: destination.path,
                updated: false,
                deferred: true
            )
        }

        try applyStagedUpdate(staged, to: destination)

        return UpdateInstallResult(
            previousVersion: currentVersion,
            version: staged.version,
            path: destination.path,
            updated: true,
            deferred: false
        )
    }

    /// Download the versioned app ZIP + checksum, extract exactly one `Semantouch.app`,
    /// and fully validate it. Returns a staged bundle ready for `applyStagedUpdate`.
    public func stageLatest(
        currentVersion: String = MCPServer.serverVersion
    ) async throws -> StagedAppUpdate {
        let release = try await latestRelease()
        let current = try SemanticVersion(currentVersion)
        return try await stageLatest(release: release, expectedMinimum: current)
    }

    /// Validate an already-extracted app bundle (shape, versions, Team, signatures,
    /// notarization/Gatekeeper where injectable).
    public func verifyAppBundle(
        at appURL: URL,
        expectedVersion: String
    ) throws {
        try Self.verifyAppBundleLayout(
            at: appURL,
            expectedVersion: expectedVersion,
            fileManager: fileManager
        )
        try signatureValidator(appURL)
        try notarizationValidator(appURL)
    }

    /// Same-volume staged rename with backup/rollback. Never replaces nested executables.
    public func applyStagedUpdate(
        _ staged: StagedAppUpdate,
        to destination: URL
    ) throws {
        let destination = try resolveAppBundleDestination(destination)
        try refuseUnwritableSystemInstall(destination)
        try refuseCrossVolume(staged.stagedAppURL, destination)

        if let installed = try? installedBundleVersion(at: destination),
           let installedVersion = try? SemanticVersion(installed),
           let stagedVersion = try? SemanticVersion(staged.version),
           installedVersion > stagedVersion {
            throw UpdateError.downgradeRefused(
                current: installedVersion.description,
                candidate: staged.version
            )
        }

        try verifyAppBundle(at: staged.stagedAppURL, expectedVersion: staged.version)

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let lockPath = parent.appendingPathComponent(".semantouch-app-update.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else {
            throw UpdateError.replacementFailed(
                path: destination.path,
                reason: String(cString: strerror(errno))
            )
        }
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw UpdateError.replacementFailed(
                path: destination.path,
                reason: String(cString: strerror(errno))
            )
        }

        // Re-check after lock: another updater may have won.
        if let installed = try? installedBundleVersion(at: destination),
           let installedVersion = try? SemanticVersion(installed),
           let stagedVersion = try? SemanticVersion(staged.version),
           installedVersion >= stagedVersion {
            return
        }

        let backup = parent.appendingPathComponent(
            ".Semantouch.app.backup-\(UUID().uuidString)"
        )
        let incoming = parent.appendingPathComponent(
            ".Semantouch.app.incoming-\(UUID().uuidString)"
        )
        defer {
            try? fileManager.removeItem(at: incoming)
            // backup is removed only after successful cutover
        }

        do {
            try fileManager.copyItem(at: staged.stagedAppURL, to: incoming)
        } catch {
            throw UpdateError.replacementFailed(
                path: destination.path,
                reason: error.localizedDescription
            )
        }

        let hadExisting = fileManager.fileExists(atPath: destination.path)
        if hadExisting {
            do {
                try fileManager.moveItem(at: destination, to: backup)
            } catch {
                throw UpdateError.replacementFailed(
                    path: destination.path,
                    reason: error.localizedDescription
                )
            }
        }

        do {
            try fileManager.moveItem(at: incoming, to: destination)
        } catch {
            // Rollback
            if hadExisting {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw UpdateError.replacementFailed(
                path: destination.path,
                reason: error.localizedDescription
            )
        }

        // Post-apply verification; roll back on failure.
        do {
            try verifyAppBundle(at: destination, expectedVersion: staged.version)
        } catch {
            if hadExisting {
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: backup, to: destination)
            } else {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }

        try? fileManager.removeItem(at: backup)
    }

    // MARK: - Staging internals

    private func stageLatest(
        release: GitHubRelease,
        expectedMinimum: SemanticVersion
    ) async throws -> StagedAppUpdate {
        if release.version < expectedMinimum {
            throw UpdateError.downgradeRefused(
                current: expectedMinimum.description,
                candidate: release.version.description
            )
        }

        #if !arch(arm64) && !arch(x86_64)
        throw UpdateError.unsupportedArchitecture
        #endif

        let version = release.version.description
        let zipName = Packaging.appZipAssetName(forVersion: version)
        let checksumName = Packaging.appZipChecksumAssetName(forVersion: version)

        guard let zipURL = release.asset(named: zipName) else {
            throw UpdateError.missingAsset(zipName)
        }
        guard let checksumURL = release.asset(named: checksumName) else {
            throw UpdateError.missingAsset(checksumName)
        }

        async let zipDownload = data(from: zipURL)
        async let checksumDownload = data(from: checksumURL)
        let (zipData, checksumData) = try await (zipDownload, checksumDownload)
        let expectedChecksum = try parseChecksum(checksumData)
        guard sha256(zipData) == expectedChecksum else {
            throw UpdateError.checksumMismatch
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("semantouch-app-stage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let zipFile = stagingRoot.appendingPathComponent(zipName)
        let extractDir = stagingRoot.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

        do {
            try zipData.write(to: zipFile, options: .atomic)
            try extractZip(zipFile, into: extractDir)
        } catch let error as UpdateError {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw UpdateError.invalidExtractionShape(error.localizedDescription)
        }

        let appURL: URL
        do {
            appURL = try locateExactlyOneApp(in: extractDir)
            try verifyAppBundle(at: appURL, expectedVersion: version)
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        return StagedAppUpdate(
            version: version,
            stagedAppURL: appURL,
            stagingRootURL: stagingRoot,
            zipChecksum: expectedChecksum
        )
    }

    // MARK: - Bundle layout verification

    static func verifyAppBundleLayout(
        at appURL: URL,
        expectedVersion: String,
        fileManager: FileManager = .default
    ) throws {
        guard appURL.lastPathComponent == Packaging.appBundleName else {
            throw UpdateError.invalidBundle(
                "expected leaf name \(Packaging.appBundleName), got \(appURL.lastPathComponent)"
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateError.invalidBundle("app path is not a directory: \(appURL.path)")
        }

        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlist.path) else {
            throw UpdateError.invalidBundle("missing Contents/Info.plist")
        }
        guard let plist = NSDictionary(contentsOf: infoPlist) as? [String: Any] else {
            throw UpdateError.invalidBundle("unreadable Contents/Info.plist")
        }

        let bundleId = plist["CFBundleIdentifier"] as? String
        guard bundleId == Packaging.bundleId else {
            throw UpdateError.invalidBundle(
                "CFBundleIdentifier \(bundleId ?? "<nil>") != \(Packaging.bundleId)"
            )
        }

        let executable = plist["CFBundleExecutable"] as? String
        guard executable == Packaging.hostExecutableName else {
            throw UpdateError.invalidBundle(
                "CFBundleExecutable \(executable ?? "<nil>") != \(Packaging.hostExecutableName)"
            )
        }

        let shortVersion = plist["CFBundleShortVersionString"] as? String
        let bundleVersion = plist["CFBundleVersion"] as? String
        guard shortVersion == expectedVersion else {
            throw UpdateError.downloadedVersionMismatch(
                expected: expectedVersion,
                actual: shortVersion
            )
        }
        if let bundleVersion, bundleVersion != expectedVersion {
            throw UpdateError.downloadedVersionMismatch(
                expected: expectedVersion,
                actual: bundleVersion
            )
        }

        let host = appURL.appendingPathComponent(Packaging.hostRelativePath)
        let relay = appURL.appendingPathComponent(Packaging.relayRelativePath)
        guard fileManager.isExecutableFile(atPath: host.path) else {
            throw UpdateError.invalidBundle("missing host executable at \(Packaging.hostRelativePath)")
        }
        guard fileManager.isExecutableFile(atPath: relay.path) else {
            throw UpdateError.invalidBundle("missing relay executable at \(Packaging.relayRelativePath)")
        }

        // Refuse a raw helper nested inside the bundle.
        let rawHelper = appURL.appendingPathComponent("Contents/MacOS/semantouch-macos-arm64")
        if fileManager.fileExists(atPath: rawHelper.path) {
            throw UpdateError.invalidBundle("raw helper binary must not be nested inside the app bundle")
        }
    }

    // MARK: - Signature / notarization

    static func validateAppBundleSignature(at appURL: URL) throws {
        // Outer app bundle.
        try validateCode(
            at: appURL,
            expectedIdentifier: Packaging.bundleId,
            deep: true
        )
        // Nested host (from a path; codesign may collapse nested display, but
        // SecStaticCodeCheckValidity on the nested path still validates the leaf).
        let host = appURL.appendingPathComponent(Packaging.hostRelativePath)
        try validateCode(
            at: host,
            expectedIdentifier: Packaging.bundleId,
            deep: false
        )
        // Nested relay.
        let relay = appURL.appendingPathComponent(Packaging.relayRelativePath)
        try validateCode(
            at: relay,
            expectedIdentifier: Packaging.relayCodeIdentifier,
            deep: false
        )
    }

    private static func validateCode(
        at url: URL,
        expectedIdentifier: String,
        deep: Bool
    ) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }

        let requirementText = """
            anchor apple generic and identifier "\(expectedIdentifier)" \
            and certificate leaf[subject.OU] = "\(Packaging.teamIdentifier)" \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
            """
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }
        let flags: SecCSFlags = deep
            ? SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate)
            : SecCSFlags(rawValue: kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }
    }

    static func validateNotarization(at appURL: URL) throws {
        // Prefer SecAssessment when available; fall back to spctl --assess for
        // a Gatekeeper opinion. Injectable in tests.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", "--verbose=4", appURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UpdateError.notarizationFailed(error.localizedDescription)
        }
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let detail = [err, out].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.notarizationFailed(detail.isEmpty ? "spctl exit \(process.terminationStatus)" : detail)
        }
    }

    private static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    // MARK: - Destination / write checks

    func resolveAppBundleDestination(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL
        // If a nested executable path was supplied, refuse rather than silently
        // rewriting — callers must pass Semantouch.app.
        let leaf = path.lastPathComponent
        if leaf == Packaging.hostExecutableName || leaf == Packaging.relayExecutableName {
            throw UpdateError.nestedExecutableReplacementRefused(path: path.path)
        }
        if leaf == "MacOS",
           path.deletingLastPathComponent().lastPathComponent == "Contents" {
            throw UpdateError.nestedExecutableReplacementRefused(path: path.path)
        }
        // Allow a path that ends with Contents/... only as refusal.
        if path.path.contains("/\(Packaging.appBundleName)/Contents/") {
            throw UpdateError.nestedExecutableReplacementRefused(path: path.path)
        }
        if leaf != Packaging.appBundleName {
            // If the path is a directory that does not yet exist, require the leaf name.
            throw UpdateError.invalidBundle(
                "destination must be named \(Packaging.appBundleName), got \(leaf)"
            )
        }
        return path
    }

    /// Walk up from a nested host/relay path to the enclosing Semantouch.app.
    /// Used only by the legacy `executablePath` entry; HostController should pass
    /// the app bundle URL directly.
    private func enclosingAppBundle(forExecutablePath executablePath: String) throws -> URL {
        var url = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
        if url.lastPathComponent == Packaging.appBundleName {
            return url
        }
        // .../Semantouch.app/Contents/MacOS/<leaf>
        for _ in 0..<6 {
            if url.lastPathComponent == Packaging.appBundleName {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        throw UpdateError.nestedExecutableReplacementRefused(path: executablePath)
    }

    private func refuseUnwritableSystemInstall(_ destination: URL) throws {
        let system = URL(fileURLWithPath: systemAppPath()).standardizedFileURL
        if destination.standardizedFileURL.path == system.path,
           !isWritableDestination(destination) {
            throw UpdateError.destinationNotWritable(path: destination.path)
        }
        // Also refuse any destination whose parent is not writable.
        if fileManager.fileExists(atPath: destination.path) {
            if !fileManager.isWritableFile(atPath: destination.path)
                || !fileManager.isWritableFile(atPath: destination.deletingLastPathComponent().path) {
                throw UpdateError.destinationNotWritable(path: destination.path)
            }
        } else if !isWritableDestination(destination) {
            throw UpdateError.destinationNotWritable(path: destination.path)
        }
    }

    private func isWritableDestination(_ destination: URL) -> Bool {
        let parent = destination.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destination.path) {
            return fileManager.isWritableFile(atPath: destination.path)
                && fileManager.isWritableFile(atPath: parent.path)
        }
        // Parent must exist and be writable for a fresh install.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return fileManager.isWritableFile(atPath: parent.path)
        }
        // Parent does not exist yet — walk up for a writable ancestor (user Applications).
        var cursor = parent
        for _ in 0..<4 {
            if fileManager.fileExists(atPath: cursor.path) {
                return fileManager.isWritableFile(atPath: cursor.path)
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path { break }
            cursor = next
        }
        return false
    }

    private func refuseCrossVolume(_ source: URL, _ destination: URL) throws {
        guard let sourceID = volumeIdentifier(of: source) as? NSObject,
              let destParentID = (volumeIdentifier(of: destination.deletingLastPathComponent())
                ?? volumeIdentifier(of: destination)) as? NSObject
        else {
            // If we cannot determine, proceed — rename will fail loudly if cross-volume.
            return
        }
        if !sourceID.isEqual(destParentID) {
            throw UpdateError.crossVolumeReplacement(path: destination.path)
        }
    }

    private func volumeIdentifier(of url: URL) -> Any? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    private func installedBundleVersion(at appURL: URL) throws -> String {
        let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoPlist) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String
        else {
            throw UpdateError.invalidBundle("installed app has no readable version")
        }
        return version
    }

    // MARK: - ZIP helpers

    private func extractZip(_ zipFile: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipFile.path, directory.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UpdateError.invalidExtractionShape(error.localizedDescription)
        }
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.invalidExtractionShape(
                err.isEmpty ? "ditto exit \(process.terminationStatus)" : err
            )
        }
    }

    private func locateExactlyOneApp(in directory: URL) throws -> URL {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UpdateError.invalidExtractionShape(error.localizedDescription)
        }

        // Prefer a top-level Semantouch.app; also accept a single nested container
        // that itself contains exactly one Semantouch.app.
        let topLevelApps = contents.filter { $0.lastPathComponent == Packaging.appBundleName }
        if topLevelApps.count == 1, contents.count == 1 {
            return topLevelApps[0]
        }
        if topLevelApps.count == 1, contents.allSatisfy({ $0.lastPathComponent == Packaging.appBundleName }) {
            return topLevelApps[0]
        }
        if topLevelApps.count > 1 {
            throw UpdateError.invalidExtractionShape("archive contains multiple \(Packaging.appBundleName) bundles")
        }

        // Single directory container → look one level down.
        let directories = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if directories.count == 1, contents.count == 1 {
            let nested = try fileManager.contentsOfDirectory(
                at: directories[0],
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            let nestedApps = nested.filter { $0.lastPathComponent == Packaging.appBundleName }
            if nestedApps.count == 1, nested.count == 1 {
                return nestedApps[0]
            }
        }

        if topLevelApps.count == 1 {
            // Extra siblings are not allowed — the release ZIP must contain exactly the app.
            throw UpdateError.invalidExtractionShape(
                "archive must contain exactly one \(Packaging.appBundleName) and nothing else"
            )
        }

        throw UpdateError.invalidExtractionShape(
            "archive must contain exactly one \(Packaging.appBundleName)"
        )
    }

    // MARK: - Network

    private func latestRelease() async throws -> GitHubRelease {
        let data = try await data(from: releaseURL)
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let version = try SemanticVersion(response.tagName)
        return GitHubRelease(version: version, assets: response.assets)
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("semantouch/\(MCPServer.serverVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return data
    }

    private func parseChecksum(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: { $0.isWhitespace }).first
        else {
            throw UpdateError.invalidChecksum
        }
        let checksum = String(token).lowercased()
        guard checksum.utf8.count == 64,
              checksum.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else {
            throw UpdateError.invalidChecksum
        }
        return checksum
    }

    private func sha256(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }
}

// MARK: - GitHub models

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        var name: String
        var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    var tagName: String
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubRelease {
    var version: SemanticVersion
    var assets: [GitHubReleaseResponse.Asset]

    func asset(named name: String) -> URL? {
        assets.first { $0.name == name }?.browserDownloadURL
    }
}

// MARK: - Semantic version

struct SemanticVersion: Comparable, CustomStringConvertible {
    private enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    private var major: Int
    private var minor: Int
    private var patch: Int
    private var prerelease: [Identifier]

    init(_ rawValue: String) throws {
        let unprefixed = rawValue.first == "v" ? String(rawValue.dropFirst()) : rawValue
        let versionParts = unprefixed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        if versionParts.count == 2 {
            let buildIdentifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard buildIdentifiers.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy(Self.validIdentifierByte)
            }) else {
                throw UpdateError.invalidVersion(rawValue)
            }
        }
        let withoutBuild = versionParts[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]),
              let minor = Int(core[1]),
              let patch = Int(core[2]),
              major >= 0, minor >= 0, patch >= 0,
              [core[0], core[1], core[2]].allSatisfy(Self.validNumericComponent)
        else {
            throw UpdateError.invalidVersion(rawValue)
        }

        var prerelease: [Identifier] = []
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty else { throw UpdateError.invalidVersion(rawValue) }
            for identifier in identifiers {
                guard !identifier.isEmpty,
                      identifier.utf8.allSatisfy(Self.validIdentifierByte)
                else {
                    throw UpdateError.invalidVersion(rawValue)
                }
                if identifier.utf8.allSatisfy({ (48...57).contains($0) }) {
                    guard Self.validNumericComponent(identifier), let value = Int(identifier) else {
                        throw UpdateError.invalidVersion(rawValue)
                    }
                    prerelease.append(.numeric(value))
                } else {
                    prerelease.append(.text(String(identifier)))
                }
            }
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        var result = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty {
            let suffix = prerelease.map { identifier -> String in
                switch identifier {
                case let .numeric(value): String(value)
                case let .text(value): value
                }
            }.joined(separator: ".")
            result += "-" + suffix
        }
        return result
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let leftCore = [lhs.major, lhs.minor, lhs.patch]
        let rightCore = [rhs.major, rhs.minor, rhs.patch]
        if leftCore != rightCore {
            return leftCore.lexicographicallyPrecedes(rightCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case let (.numeric(a), .numeric(b)): return a < b
            case (.numeric, .text): return true
            case (.text, .numeric): return false
            case let (.text(a), .text(b)): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func validNumericComponent(_ value: Substring) -> Bool {
        !value.isEmpty
            && value.utf8.allSatisfy { (48...57).contains($0) }
            && (value.count == 1 || value.first != "0")
    }

    private static func validIdentifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
            || byte == 45
    }
}
