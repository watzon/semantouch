import XCTest
@testable import SemantouchIPC
import Foundation
import Darwin

final class SocketLocationTests: XCTestCase {
    private var tempRoot: URL!
    private var euid: uid_t!

    override func setUpWithError() throws {
        try super.setUpWithError()
        euid = geteuid()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-\(UInt64.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func testResolveCreates0700Directory() throws {
        let location = try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
        var st = stat()
        XCTAssertEqual(lstat(location.directoryPath, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(st.st_uid, euid)
        XCTAssertTrue(location.socketPath.hasSuffix("/\(HostProtocol.socketFileName)"))
        XCTAssertTrue(location.socketPath.contains(HostProtocol.runtimeDirectoryName))
    }

    func testPathTooLongRejected() {
        let long = String(repeating: "a", count: 200)
        XCTAssertThrowsError(try SocketLocation.validatePathLength(long)) { error in
            guard case .pathTooLong? = error as? IPCError else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }

    func testSunPathLimitIs104() {
        XCTAssertEqual(SocketLocation.sunPathLimit, 104)
        // 103 chars + NUL = 104 fits; 104 chars + NUL does not.
        let ok = String(repeating: "b", count: 103)
        XCTAssertNoThrow(try SocketLocation.validatePathLength(ok))
        let bad = String(repeating: "c", count: 104)
        XCTAssertThrowsError(try SocketLocation.validatePathLength(bad))
    }

    func testSymlinkDirectoryRejected() throws {
        let real = tempRoot.appendingPathComponent("real-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        // Force 0700
        XCTAssertEqual(chmod(real.path, 0o700), 0)

        let link = tempRoot.appendingPathComponent("link-dir")
        XCTAssertEqual(symlink(real.path, link.path), 0)

        XCTAssertThrowsError(
            try SocketLocation.validateDirectory(link.path, euid: euid)
        ) { error in
            guard case let .directoryInvalid(_, reason)? = error as? IPCError else {
                return XCTFail("expected directoryInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("symlink"), reason)
        }
    }

    func testPermissiveDirectoryModeRejected() throws {
        let dir = tempRoot.appendingPathComponent("open-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertThrowsError(
            try SocketLocation.validateDirectory(dir.path, euid: euid)
        ) { error in
            guard case let .directoryInvalid(_, reason)? = error as? IPCError else {
                return XCTFail("expected directoryInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("0700"), reason)
        }
    }

    func testWrongTypeSocketRejected() throws {
        let location = try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
        // Create a regular file where the socket should be.
        XCTAssertTrue(FileManager.default.createFile(
            atPath: location.socketPath,
            contents: Data("not-a-socket".utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertThrowsError(
            try SocketLocation.validateSocketPath(location.socketPath, euid: euid)
        ) { error in
            guard case let .socketInvalid(_, reason)? = error as? IPCError else {
                return XCTFail("expected socketInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("not a socket"), reason)
        }
    }

    func testSymlinkSocketRejected() throws {
        let location = try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
        let target = location.directoryURL.appendingPathComponent("target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        XCTAssertEqual(symlink(target.path, location.socketPath), 0)
        XCTAssertThrowsError(
            try SocketLocation.validateSocketPath(location.socketPath, euid: euid)
        ) { error in
            guard case let .socketInvalid(_, reason)? = error as? IPCError else {
                return XCTFail("expected socketInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("symlink"), reason)
        }
    }

    func testPermissiveSocketModeRejected() throws {
        // Bind a real socket, then chmod to 0666 and validate.
        let location = try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
        let listener = HostListener(
            location: location,
            policy: .hostAcceptsRelay(relayExecutablePath: nil, euid: euid),
            verifier: AcceptingPeerVerifier(requireEUID: false),
            euid: euid
        )
        try listener.start()
        defer { listener.stop() }

        XCTAssertEqual(chmod(location.socketPath, 0o666), 0)
        XCTAssertThrowsError(
            try SocketLocation.validateSocketPath(location.socketPath, euid: euid)
        ) { error in
            guard case let .socketInvalid(_, reason)? = error as? IPCError else {
                return XCTFail("expected socketInvalid, got \(error)")
            }
            XCTAssertTrue(reason.contains("0600"), reason)
        }
    }

    func testValidSocketPathAccepted() throws {
        let location = try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
        let listener = HostListener(
            location: location,
            policy: .hostAcceptsRelay(relayExecutablePath: nil, euid: euid),
            verifier: AcceptingPeerVerifier(requireEUID: false),
            euid: euid
        )
        try listener.start()
        defer { listener.stop() }

        XCTAssertNoThrow(
            try SocketLocation.validateSocketPath(location.socketPath, euid: euid)
        )
        var st = stat()
        XCTAssertEqual(lstat(location.socketPath, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }
}
