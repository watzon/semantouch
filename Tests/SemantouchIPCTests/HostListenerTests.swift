import XCTest
@testable import SemantouchIPC
import Foundation
import Darwin

final class HostListenerTests: XCTestCase {
    private var tempRoot: URL!
    private var euid: uid_t!

    override func setUpWithError() throws {
        try super.setUpWithError()
        euid = geteuid()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-\(UInt64.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeLocation() throws -> SocketLocation {
        try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
    }

    private func makeListener(
        location: SocketLocation,
        verifier: any PeerVerifying = AcceptingPeerVerifier(requireEUID: true)
    ) -> HostListener {
        HostListener(
            location: location,
            policy: .hostAcceptsRelay(relayExecutablePath: nil, euid: euid),
            verifier: verifier,
            euid: euid
        )
    }

    func testTwoListenersSecondFailsLock() throws {
        let location = try makeLocation()
        let first = makeListener(location: location)
        try first.start()
        defer { first.stop() }

        let second = makeListener(location: location)
        XCTAssertThrowsError(try second.start()) { error in
            guard case .lockBusy? = error as? IPCError else {
                return XCTFail("expected lockBusy, got \(error)")
            }
        }
    }

    func testStaleSocketCleanupByLockOwner() throws {
        let location = try makeLocation()
        // First listener creates a socket then is force-stopped without unlink
        // simulation: start, stop (stop unlinks). Instead, manually bind a socket
        // and leave it, then start a new listener which should clean it up.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
            XCTAssertEqual(Darwin.bind(fd, addr, len), 0)
        }
        XCTAssertEqual(chmod(location.socketPath, 0o600), 0)
        // Don't listen — just leave a stale bound socket inode after close.
        close(fd)

        // Socket path still exists as a dead socket file.
        var st = stat()
        XCTAssertEqual(lstat(location.socketPath, &st), 0)

        let listener = makeListener(location: location)
        try listener.start()
        defer { listener.stop() }
        XCTAssertTrue(listener.isListening)
    }

    func testStaleSymlinkRejectedNotCleaned() throws {
        let location = try makeLocation()
        let target = location.directoryURL.appendingPathComponent("elsewhere")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data()))
        XCTAssertEqual(symlink(target.path, location.socketPath), 0)

        let listener = makeListener(location: location)
        XCTAssertThrowsError(try listener.start()) { error in
            guard case let .staleSocketRejected(_, reason)? = error as? IPCError else {
                return XCTFail("expected staleSocketRejected, got \(error)")
            }
            XCTAssertTrue(reason.contains("symlink"), reason)
        }
        // Symlink must still exist (not cleaned up).
        var st = stat()
        XCTAssertEqual(lstat(location.socketPath, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK)
    }

    func testStaleRegularFileRejected() throws {
        let location = try makeLocation()
        XCTAssertTrue(FileManager.default.createFile(
            atPath: location.socketPath,
            contents: Data("nope".utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        let listener = makeListener(location: location)
        XCTAssertThrowsError(try listener.start()) { error in
            guard case let .staleSocketRejected(_, reason)? = error as? IPCError else {
                return XCTFail("expected staleSocketRejected, got \(error)")
            }
            XCTAssertTrue(reason.contains("not a socket"), reason)
        }
    }

    func testStalePermissiveModeRejected() throws {
        let location = try makeLocation()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
            XCTAssertEqual(Darwin.bind(fd, addr, len), 0)
        }
        XCTAssertEqual(chmod(location.socketPath, 0o666), 0)
        close(fd)

        let listener = makeListener(location: location)
        XCTAssertThrowsError(try listener.start()) { error in
            guard case let .staleSocketRejected(_, reason)? = error as? IPCError else {
                return XCTFail("expected staleSocketRejected, got \(error)")
            }
            XCTAssertTrue(reason.contains("0600"), reason)
        }
    }

    func testPeerRejectionClosesConnection() throws {
        let location = try makeLocation()
        let listener = makeListener(
            location: location,
            verifier: RejectingPeerVerifier(reason: "wrong team")
        )
        try listener.start()
        defer { listener.stop() }

        // Connect as a client.
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)
        defer { close(clientFD) }
        try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
            XCTAssertEqual(Darwin.connect(clientFD, addr, len), 0)
        }

        let acceptResult = Result { try listener.accept() }
        XCTAssertThrowsError(try acceptResult.get()) { error in
            guard case let .peerRejected(reason)? = error as? IPCError else {
                return XCTFail("expected peerRejected, got \(error)")
            }
            XCTAssertEqual(reason, "wrong team")
        }
    }

    func testAcceptingPeerVerifierAllowsSameEUID() throws {
        let location = try makeLocation()
        let listener = makeListener(
            location: location,
            verifier: AcceptingPeerVerifier(requireEUID: true)
        )
        try listener.start()
        defer { listener.stop() }

        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)
        defer { close(clientFD) }
        try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
            XCTAssertEqual(Darwin.connect(clientFD, addr, len), 0)
        }

        let accepted = try listener.accept()
        defer { accepted.connection.close() }
        XCTAssertEqual(accepted.peer.euid, euid)
    }

    func testHelloNonceAndVersion() throws {
        let location = try makeLocation()
        let listener = makeListener(location: location)
        try listener.start()
        defer { listener.stop() }

        let client = HostClient(
            location: location,
            policy: .relayAcceptsHost(hostExecutablePath: nil, euid: euid),
            clientVersion: "test-client",
            verifier: AcceptingPeerVerifier(requireEUID: true),
            euid: euid
        )

        let bootId = UUID().uuidString
        let group = DispatchGroup()
        group.enter()
        var hostError: Error?
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                let accepted = try listener.accept()
                defer { accepted.connection.close() }
                let (_, result) = try HostListener.performHello(
                    fd: accepted.connection.fd,
                    hostVersion: "test-host",
                    bootId: bootId
                )
                XCTAssertEqual(result.bootId, bootId)
                XCTAssertEqual(result.mode, .rawMCP)
            } catch {
                hostError = error
            }
        }

        let session = try client.connect(role: .mcp, retry: .none)
        defer { session.close() }
        group.wait()
        XCTAssertNil(hostError)
        XCTAssertEqual(session.helloResult.echoNonce, session.helloRequest.nonce)
        XCTAssertEqual(session.helloResult.bootId, bootId)
        XCTAssertEqual(session.helloResult.protocol, HostProtocol.version)
        XCTAssertEqual(session.helloResult.mode, .rawMCP)
    }

    func testHelloProtocolMismatch() throws {
        let location = try makeLocation()
        let listener = makeListener(location: location)
        try listener.start()
        defer { listener.stop() }

        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)
        defer { close(clientFD) }
        try UnixSocketAddress.withSockaddr(path: location.socketPath) { addr, len in
            XCTAssertEqual(Darwin.connect(clientFD, addr, len), 0)
        }

        let group = DispatchGroup()
        group.enter()
        var hostError: Error?
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                let accepted = try listener.accept()
                defer { accepted.connection.close() }
                _ = try HostListener.performHello(
                    fd: accepted.connection.fd,
                    hostVersion: "test-host"
                )
            } catch {
                hostError = error
            }
        }

        // Send a hello with wrong protocol version.
        let bad = HelloRequest(
            protocol: 99,
            role: .mcp,
            clientVersion: "x",
            nonce: HostProtocol.makeNonceBase64()
        )
        let payload = try HostCodec.encode(bad)
        try FrameIO.writeFrame(fd: clientFD, payload: payload)
        // Host should respond with error envelope or close; either way protocolMismatch.
        group.wait()
        XCTAssertNotNil(hostError)
        if let ipc = hostError as? IPCError {
            guard case .protocolMismatch = ipc else {
                return XCTFail("expected protocolMismatch, got \(ipc)")
            }
        }
    }

    func testHelloNonceMismatchOnClient() throws {
        // Host echoes a different nonce → client rejects.
        let location = try makeLocation()
        let listener = makeListener(location: location)
        try listener.start()
        defer { listener.stop() }

        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                let accepted = try listener.accept()
                defer { accepted.connection.close() }
                // Read request, write result with wrong echoNonce.
                let payload = try FrameIO.readFrame(
                    fd: accepted.connection.fd,
                    maximumFrameBytes: HostProtocol.helloMaxFrameBytes
                )
                let request = try HostCodec.decodeHelloRequest(payload)
                var result = HelloResult.make(
                    hostVersion: "h",
                    echoNonce: request.nonce,
                    role: request.role
                )
                result.echoNonce = HostProtocol.makeNonceBase64() // wrong
                try FrameIO.writeFrame(
                    fd: accepted.connection.fd,
                    payload: try HostCodec.encode(result)
                )
            } catch {
                // ignore
            }
        }

        let client = HostClient(
            location: location,
            policy: .relayAcceptsHost(hostExecutablePath: nil, euid: euid),
            clientVersion: "c",
            verifier: AcceptingPeerVerifier(requireEUID: true),
            euid: euid
        )
        XCTAssertThrowsError(try client.connect(role: .mcp, retry: .none)) { error in
            XCTAssertEqual(error as? IPCError, .nonceMismatch)
        }
        group.wait()
    }
}
