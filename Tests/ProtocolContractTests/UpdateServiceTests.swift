import CryptoKit
import Foundation
import XCTest
import ComputerUseCore
@testable import ComputerUseService

final class UpdateServiceTests: XCTestCase {
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

    func testCheckReportsAvailableRelease() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })

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
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })

        let check = await service.check(currentVersion: "0.4.0")

        XCTAssertEqual(check.status, .upToDate)
        XCTAssertEqual(check.latestVersion, "0.3.0")
    }

    func testCheckReportsUnknownWithoutFailingDoctorWhenGitHubIsUnavailable() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        StubURLProtocol.register(status: 503, data: Data(), for: fixture.releaseURL)
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })

        let check = await service.check(currentVersion: "0.2.0")

        XCTAssertEqual(check.status, .unknown)
        XCTAssertNil(check.latestVersion)
        XCTAssertEqual(check.message, "GitHub returned HTTP status 503")
    }

    func testInstallLatestChecksumVerifiesVersionAndReplacesExecutable() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let binary = Data("#!/bin/sh\nprintf '%s\\n' 'semantouch 0.3.0 (contract semantouch/1, MCP test)'\n".utf8)
        registerRelease(fixture, binary: binary, checksum: sha256(binary))
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("semantouch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old binary".utf8).write(to: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            executablePath: executable.path
        )

        XCTAssertEqual(
            result,
            UpdateInstallResult(
                previousVersion: "0.2.0",
                version: "0.3.0",
                path: executable.path,
                updated: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: executable), binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testInstallLatestLeavesExecutableUntouchedOnChecksumMismatch() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let binary = Data("not the expected binary".utf8)
        registerRelease(fixture, binary: binary, checksum: String(repeating: "0", count: 64))
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("semantouch")
        let original = Data("original binary".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await service.installLatest(
                currentVersion: "0.2.0",
                executablePath: executable.path
            )
            XCTFail("expected checksum mismatch")
        } catch {
            XCTAssertEqual(error as? UpdateError, .checksumMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: executable), original)
    }

    func testInstallLatestLeavesExecutableUntouchedOnPublisherSignatureFailure() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let binary = Data("#!/bin/sh\nprintf '%s\\n' 'semantouch 0.3.0 (contract semantouch/1, MCP test)'\n".utf8)
        registerRelease(fixture, binary: binary, checksum: sha256(binary))
        let service = UpdateService(
            session: makeSession(),
            releaseURL: fixture.releaseURL,
            signatureValidator: { _ in throw UpdateError.invalidSignature("publisher mismatch") }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("semantouch")
        let original = Data("original binary".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await service.installLatest(
                currentVersion: "0.2.0",
                executablePath: executable.path
            )
            XCTFail("expected signature failure")
        } catch {
            XCTAssertEqual(error as? UpdateError, .invalidSignature("publisher mismatch"))
        }
        XCTAssertEqual(try Data(contentsOf: executable), original)
    }

    func testStaleUpdaterDoesNotReplaceNewerInstalledHelper() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let binary = Data("#!/bin/sh\nprintf '%s\\n' 'semantouch 0.3.0 (contract semantouch/1, MCP test)'\n".utf8)
        registerRelease(fixture, binary: binary, checksum: sha256(binary))
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("semantouch")
        let newer = Data("#!/bin/sh\nprintf '%s\\n' 'semantouch 0.4.0 (contract semantouch/1, MCP test)'\n".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try newer.write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            executablePath: executable.path
        )

        XCTAssertFalse(result.updated)
        XCTAssertEqual(result.version, "0.4.0")
        XCTAssertEqual(try Data(contentsOf: executable), newer)
    }

    func testInstallLatestLeavesExecutableUntouchedWhenAssetReportsWrongVersion() async throws {
        let fixture = makeFixture(tag: "v0.3.0")
        let binary = Data("#!/bin/sh\nprintf '%s\\n' 'semantouch 0.2.5 (contract semantouch/1, MCP test)'\n".utf8)
        registerRelease(fixture, binary: binary, checksum: sha256(binary))
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantouch-update-test-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("semantouch")
        let original = Data("original binary".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: executable)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await service.installLatest(
                currentVersion: "0.2.0",
                executablePath: executable.path
            )
            XCTFail("expected version mismatch")
        } catch {
            XCTAssertEqual(
                error as? UpdateError,
                .downloadedVersionMismatch(expected: "0.3.0", actual: "0.2.5")
            )
        }
        XCTAssertEqual(try Data(contentsOf: executable), original)
    }

    func testInstallLatestDoesNotDownloadAssetsWhenAlreadyCurrent() async throws {
        let fixture = makeFixture(tag: "v0.2.0")
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        let service = UpdateService(session: makeSession(), releaseURL: fixture.releaseURL, signatureValidator: { _ in })

        let result = try await service.installLatest(
            currentVersion: "0.2.0",
            executablePath: "/unused/semantouch"
        )

        XCTAssertFalse(result.updated)
        XCTAssertEqual(result.version, "0.2.0")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeFixture(tag: String) -> ReleaseFixture {
        let id = UUID().uuidString
        let releaseURL = URL(string: "https://fixtures.invalid/\(id)/latest")!
        let binaryURL = URL(string: "https://fixtures.invalid/\(id)/semantouch-macos-arm64")!
        let checksumURL = URL(string: "https://fixtures.invalid/\(id)/semantouch-macos-arm64.sha256")!
        let payload: [String: Any] = [
            "tag_name": tag,
            "assets": [
                ["name": "semantouch-macos-arm64", "browser_download_url": binaryURL.absoluteString],
                ["name": "semantouch-macos-arm64.sha256", "browser_download_url": checksumURL.absoluteString],
            ],
        ]
        return ReleaseFixture(
            releaseURL: releaseURL,
            binaryURL: binaryURL,
            checksumURL: checksumURL,
            releaseData: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private func registerRelease(_ fixture: ReleaseFixture, binary: Data, checksum: String) {
        StubURLProtocol.register(status: 200, data: fixture.releaseData, for: fixture.releaseURL)
        StubURLProtocol.register(status: 200, data: binary, for: fixture.binaryURL)
        StubURLProtocol.register(
            status: 200,
            data: Data("\(checksum)  semantouch-macos-arm64\n".utf8),
            for: fixture.checksumURL
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ReleaseFixture {
    var releaseURL: URL
    var binaryURL: URL
    var checksumURL: URL
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
