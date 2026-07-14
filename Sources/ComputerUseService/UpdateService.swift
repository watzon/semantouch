import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security
import ComputerUseCore
import MCPServer

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

public struct UpdateInstallResult: Codable, Equatable, Sendable {
    public var previousVersion: String
    public var version: String
    public var path: String
    public var updated: Bool

    public init(previousVersion: String, version: String, path: String, updated: Bool) {
        self.previousVersion = previousVersion
        self.version = version
        self.path = path
        self.updated = updated
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
    case unsupportedArchitecture
    case downloadedVersionMismatch(expected: String, actual: String?)
    case replacementFailed(path: String, reason: String)

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
        case .unsupportedArchitecture:
            return "released Semantouch binaries currently support macOS arm64 only"
        case let .downloadedVersionMismatch(expected, actual):
            let found = actual.map { "v\($0)" } ?? "an unreadable version"
            return "the downloaded helper reported \(found), expected v\(expected)"
        case let .replacementFailed(path, reason):
            return "could not replace \(path): \(reason)"
        }
    }
}

public struct UpdateService: @unchecked Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/watzon/semantouch/releases/latest")!
    public static let binaryAssetName = "semantouch-macos-arm64"

    private let session: URLSession
    private let releaseURL: URL
    private let signatureValidator: @Sendable (URL) throws -> Void

    public init(session: URLSession = .shared, releaseURL: URL = Self.latestReleaseURL) {
        self.session = session
        self.releaseURL = releaseURL
        signatureValidator = { try Self.validateReleaseSignature(at: $0) }
    }

    init(
        session: URLSession,
        releaseURL: URL,
        signatureValidator: @escaping @Sendable (URL) throws -> Void
    ) {
        self.session = session
        self.releaseURL = releaseURL
        self.signatureValidator = signatureValidator
    }

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

    public func installLatest(
        currentVersion: String = MCPServer.serverVersion,
        executablePath: String
    ) async throws -> UpdateInstallResult {
        let release = try await latestRelease()
        let current = try SemanticVersion(currentVersion)
        let destination = URL(fileURLWithPath: executablePath)

        guard release.version > current else {
            return UpdateInstallResult(
                previousVersion: currentVersion,
                version: release.version.description,
                path: destination.path,
                updated: false
            )
        }

        #if !arch(arm64)
        throw UpdateError.unsupportedArchitecture
        #endif

        guard let binaryURL = release.asset(named: Self.binaryAssetName) else {
            throw UpdateError.missingAsset(Self.binaryAssetName)
        }
        let checksumName = Self.binaryAssetName + ".sha256"
        guard let checksumURL = release.asset(named: checksumName) else {
            throw UpdateError.missingAsset(checksumName)
        }

        async let binaryDownload = data(from: binaryURL)
        async let checksumDownload = data(from: checksumURL)
        let (binary, checksumData) = try await (binaryDownload, checksumDownload)
        let expectedChecksum = try parseChecksum(checksumData)
        guard sha256(binary) == expectedChecksum else {
            throw UpdateError.checksumMismatch
        }

        let replacement = try replaceExecutable(
            at: destination,
            with: binary,
            expectedVersion: release.version
        )

        return UpdateInstallResult(
            previousVersion: currentVersion,
            version: replacement.version,
            path: destination.path,
            updated: replacement.updated
        )
    }

    private func latestRelease() async throws -> GitHubRelease {
        let data = try await data(from: releaseURL)
        let response = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        let version = try SemanticVersion(response.tagName)
        return GitHubRelease(version: version, assets: response.assets)
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
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

    private func replaceExecutable(
        at destination: URL,
        with data: Data,
        expectedVersion: SemanticVersion
    ) throws -> (version: String, updated: Bool) {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.replacementFailed(path: destination.path, reason: error.localizedDescription)
        }

        let temporary = directory.appendingPathComponent(".semantouch-update-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        } catch {
            throw UpdateError.replacementFailed(path: destination.path, reason: error.localizedDescription)
        }

        try signatureValidator(temporary)
        let expected = expectedVersion.description
        let actualVersion = executableVersion(at: temporary)
        guard actualVersion == expected else {
            throw UpdateError.downloadedVersionMismatch(expected: expected, actual: actualVersion)
        }

        let lockPath = directory.appendingPathComponent(".semantouch-update.lock").path
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

        if let installedString = executableVersion(at: destination),
           let installedVersion = try? SemanticVersion(installedString),
           installedVersion >= expectedVersion {
            return (version: installedVersion.description, updated: false)
        }

        guard rename(temporary.path, destination.path) == 0 else {
            throw UpdateError.replacementFailed(
                path: destination.path,
                reason: String(cString: strerror(errno))
            )
        }
        return (version: expected, updated: true)
    }

    private static func validateReleaseSignature(at url: URL) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }

        let requirementText = """
            anchor apple generic
            and identifier "tech.watzon.semantouch"
            and certificate leaf[subject.OU] = "MB5789APU7"
            """
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }

        status = SecStaticCodeCheckValidity(code, [], requirement)
        guard status == errSecSuccess else {
            throw UpdateError.invalidSignature(securityMessage(status))
        }
    }

    private static func securityMessage(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    private func executableVersion(at url: URL) -> String? {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("semantouch-version-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL),
              let errors = FileHandle(forWritingAtPath: "/dev/null")
        else {
            return nil
        }
        defer {
            try? output.close()
            try? errors.close()
            try? fileManager.removeItem(at: outputURL)
        }

        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        try? output.synchronize()
        guard let data = try? Data(contentsOf: outputURL),
              let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, fields[0] == MCPServer.serverName else { return nil }
        return String(fields[1])
    }
}

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
