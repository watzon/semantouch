import XCTest
@testable import SemantouchIPC
import Foundation
import Darwin

final class HostClientAndRelayTests: XCTestCase {
    private var tempRoot: URL!
    private var euid: uid_t!

    override func setUpWithError() throws {
        try super.setUpWithError()
        euid = geteuid()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UInt64.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeLocation() throws -> SocketLocation {
        try SocketLocation.make(userTempDirectory: tempRoot, euid: euid)
    }

    func testPeerIdentityEqualityIncludesAuditToken() {
        var firstToken = audit_token_t()
        var secondToken = audit_token_t()
        firstToken.val.0 = 1
        secondToken.val.0 = 2

        let first = PeerIdentity(
            euid: 501,
            egid: 20,
            pid: 42,
            auditToken: firstToken,
            codeIdentifier: "tech.watzon.semantouch",
            teamIdentifier: "MB5789APU7",
            executablePath: "/Applications/Semantouch.app/Contents/MacOS/SemantouchHost"
        )
        var same = first
        var differentToken = first
        differentToken.auditToken = secondToken

        XCTAssertEqual(first, same)
        same.executablePath = "/tmp/SemantouchHost"
        XCTAssertNotEqual(first, same)
        XCTAssertNotEqual(first, differentToken)
    }

    func testBoundedRetryEventuallyConnects() throws {
        let location = try makeLocation()
        let policy = ConnectRetryPolicy(
            maximumAttempts: 20,
            initialDelay: 0.01,
            maximumDelay: 0.05,
            totalBudget: 2.0,
            multiplier: 1.5
        )

        var attempts: [IPCError] = []
        let client = HostClient(
            location: location,
            policy: .relayAcceptsHost(hostExecutablePath: nil, euid: euid),
            clientVersion: "c",
            verifier: AcceptingPeerVerifier(requireEUID: true),
            euid: euid
        )

        // Start listener after a short delay so the first attempts fail.
        let listener = HostListener(
            location: location,
            policy: .hostAcceptsRelay(relayExecutablePath: nil, euid: euid),
            verifier: AcceptingPeerVerifier(requireEUID: true),
            euid: euid
        )
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            usleep(80_000) // 80 ms
            try? listener.start()
        }

        // Accept + hello on another thread once listening.
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            // Wait until listening.
            for _ in 0..<100 {
                if listener.isListening { break }
                usleep(10_000)
            }
            guard listener.isListening else { return }
            do {
                let accepted = try listener.accept()
                defer { accepted.connection.close() }
                _ = try HostListener.performHello(
                    fd: accepted.connection.fd,
                    hostVersion: "h"
                )
            } catch {
                // ignore
            }
        }

        let session = try client.connect(
            role: .mcp,
            retry: policy,
            onRetry: { _, error in attempts.append(error) }
        )
        defer {
            session.close()
            listener.stop()
        }
        group.wait()
        XCTAssertFalse(attempts.isEmpty, "expected at least one pre-hello retry")
        for error in attempts {
            XCTAssertTrue(error.isPreHelloRetryable, "\(error)")
        }
        XCTAssertEqual(session.helloResult.mode, .rawMCP)
    }

    func testRetryExhaustedWhenHostNeverAppears() throws {
        let location = try makeLocation()
        let client = HostClient(
            location: location,
            policy: .relayAcceptsHost(hostExecutablePath: nil, euid: euid),
            clientVersion: "c",
            verifier: AcceptingPeerVerifier(requireEUID: true),
            euid: euid
        )
        let policy = ConnectRetryPolicy(
            maximumAttempts: 3,
            initialDelay: 0.001,
            maximumDelay: 0.002,
            totalBudget: 0.1,
            multiplier: 1.0
        )
        var attempts = 0
        XCTAssertThrowsError(
            try client.connectWithRetry(retry: policy, onRetry: { _, _ in attempts += 1 })
        ) { error in
            // Final error is either the last connectFailed or retryExhausted.
            let ipc = error as? IPCError
            XCTAssertNotNil(ipc)
            if let ipc {
                XCTAssertTrue(
                    {
                        if case .connectFailed = ipc { return true }
                        if case .retryExhausted = ipc { return true }
                        return false
                    }(),
                    "unexpected \(ipc)"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(attempts, 1)
    }

    func testRetryDelayBounds() {
        let policy = ConnectRetryPolicy(
            maximumAttempts: 10,
            initialDelay: 0.05,
            maximumDelay: 0.5,
            totalBudget: 5,
            multiplier: 1.6
        )
        XCTAssertEqual(policy.delay(forAttempt: 1), 0.05, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(policy.delay(forAttempt: 20), 0.5)
        XCTAssertEqual(ConnectRetryPolicy.none.maximumAttempts, 1)
    }

    func testOpaqueRelayExactByteTransparency() throws {
        // socketpair: A <-> B
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let left = fds[0]
        let right = fds[1]
        defer {
            close(left)
            close(right)
        }

        // Second pair for the "stdio" side so we don't touch real stdio.
        var stdio: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &stdio), 0)
        let stdioClient = stdio[0] // test writes here as "stdin", reads as "stdout"
        let stdioRelay = stdio[1]  // relay side
        defer {
            close(stdioClient)
            close(stdioRelay)
        }

        // Actually for bidirectional transparency test, pump left↔right with known bytes.
        let payloadAB = Data((0..<4096).map { UInt8($0 % 251) })
        let payloadBA = Data((0..<3000).map { UInt8(255 - ($0 % 251)) })

        let relay = OpaqueRelay(bufferSize: 512)
        let group = DispatchGroup()

        group.enter()
        var relayResult: OpaqueRelay.Result?
        Thread.detachNewThread {
            defer { group.leave() }
            relayResult = relay.run(
                a: OpaqueRelay.Endpoint(fd: left, label: "left"),
                b: OpaqueRelay.Endpoint(fd: right, label: "right")
            )
        }

        // Write A→B from an extra writer on left? Wait — left is already the relay endpoint.
        // Better approach: use two socketpairs and relay across them.
        // Restart with a cleaner topology.
        // Cancel this approach: close and use the topology below.
        // Signal EOF so the pump can finish quickly if it started.
        shutdown(left, SHUT_WR)
        shutdown(right, SHUT_WR)
        group.wait()
        _ = relayResult
        _ = payloadAB
        _ = payloadBA
        _ = stdioClient
        _ = stdioRelay

        try runByteTransparencyTopology()
    }

    private func runByteTransparencyTopology() throws {
        // pair1: producerA <-> relayA
        // pair2: relayB <-> consumerB
        // Relay pumps relayA <-> relayB.
        // We write to producerA and read from consumerB, and vice versa.

        var pair1: [Int32] = [0, 0]
        var pair2: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair1), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair2), 0)
        let producerA = pair1[0]
        let relayA = pair1[1]
        let relayB = pair2[0]
        let consumerB = pair2[1]
        defer {
            close(producerA); close(relayA); close(relayB); close(consumerB)
        }

        let forward = Data((0..<8192).map { UInt8($0 % 251) })
        let backward = Data("MCP-like\n{\"jsonrpc\":\"2.0\"}\n".utf8)
            + Data((0..<1024).map { UInt8(200 - ($0 % 200)) })

        let relay = OpaqueRelay(bufferSize: 256)
        let group = DispatchGroup()
        group.enter()
        var result: OpaqueRelay.Result?
        Thread.detachNewThread {
            defer { group.leave() }
            result = relay.run(
                a: OpaqueRelay.Endpoint(fd: relayA, label: "a"),
                b: OpaqueRelay.Endpoint(fd: relayB, label: "b")
            )
        }

        // Write forward and backward concurrently.
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            _ = forward.withUnsafeBytes { raw in
                write(producerA, raw.baseAddress!, forward.count)
            }
            shutdown(producerA, SHUT_WR)
        }
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            _ = backward.withUnsafeBytes { raw in
                write(consumerB, raw.baseAddress!, backward.count)
            }
            shutdown(consumerB, SHUT_WR)
        }

        // Read all from opposite ends.
        let gotForward = readAll(fd: consumerB, expected: forward.count)
        let gotBackward = readAll(fd: producerA, expected: backward.count)

        group.wait()

        XCTAssertEqual(gotForward, forward, "forward path must be byte-exact")
        XCTAssertEqual(gotBackward, backward, "backward path must be byte-exact")
        XCTAssertEqual(result?.bytesAtoB, forward.count)
        XCTAssertEqual(result?.bytesBtoA, backward.count)
        XCTAssertNil(result?.errorDescription)
    }

    func testHalfClosePropagatesEOF() throws {
        var pair1: [Int32] = [0, 0]
        var pair2: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair1), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair2), 0)
        let srcClient = pair1[0]
        let srcRelay = pair1[1]
        let dstRelay = pair2[0]
        let dstClient = pair2[1]
        defer {
            close(srcClient); close(srcRelay); close(dstRelay); close(dstClient)
        }

        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            _ = try? OpaqueRelay.pump(
                from: OpaqueRelay.Endpoint(fd: srcRelay, label: "src", halfCloseOnEOF: true),
                to: OpaqueRelay.Endpoint(fd: dstRelay, label: "dst", halfCloseOnEOF: true),
                bufferSize: 128
            )
        }

        let message = Data("half-close-check".utf8)
        _ = message.withUnsafeBytes { write(srcClient, $0.baseAddress!, message.count) }
        shutdown(srcClient, SHUT_WR) // EOF toward relay

        let got = readAll(fd: dstClient, expected: message.count)
        XCTAssertEqual(got, message)

        // Destination write side should be half-closed → further read yields EOF.
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(dstClient, &buf, buf.count)
        XCTAssertEqual(n, 0, "expected EOF after half-close")
        group.wait()
    }

    func testStdioRelayMapping() throws {
        // stdinPair: test→relay stdin
        // stdoutPair: relay stdout→test
        // socketPair: relay socket ↔ peer
        var stdinPair: [Int32] = [0, 0]
        var stdoutPair: [Int32] = [0, 0]
        var socketPair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &stdinPair), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &stdoutPair), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &socketPair), 0)

        let testStdinWrite = stdinPair[0]
        let relayStdin = stdinPair[1]
        let relayStdout = stdoutPair[0]
        let testStdoutRead = stdoutPair[1]
        let relaySocket = socketPair[0]
        let peerSocket = socketPair[1]
        defer {
            for fd in [testStdinWrite, relayStdin, relayStdout, testStdoutRead, relaySocket, peerSocket] {
                close(fd)
            }
        }

        let relay = OpaqueRelay(bufferSize: 64)
        let group = DispatchGroup()
        group.enter()
        var result: OpaqueRelay.Result?
        Thread.detachNewThread {
            defer { group.leave() }
            result = relay.runStdio(
                stdinFD: relayStdin,
                stdoutFD: relayStdout,
                socketFD: relaySocket
            )
        }

        let up = Data("from-client-stdin".utf8)
        let down = Data("from-host-socket".utf8)

        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            _ = up.withUnsafeBytes { write(testStdinWrite, $0.baseAddress!, up.count) }
            shutdown(testStdinWrite, SHUT_WR)
        }
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            _ = down.withUnsafeBytes { write(peerSocket, $0.baseAddress!, down.count) }
            shutdown(peerSocket, SHUT_WR)
        }

        let gotOnPeer = readAll(fd: peerSocket, expected: up.count)
        let gotOnStdout = readAll(fd: testStdoutRead, expected: down.count)
        group.wait()

        XCTAssertEqual(gotOnPeer, up)
        XCTAssertEqual(gotOnStdout, down)
        XCTAssertEqual(result?.bytesAtoB, up.count)
        XCTAssertEqual(result?.bytesBtoA, down.count)
    }

    func testPeerVerifierFakeRejectionPaths() throws {
        let location = try makeLocation()
        // Wrong euid on fixed identity.
        let badIdentity = PeerIdentity(
            euid: euid &+ 1,
            egid: 0,
            pid: 1,
            auditToken: audit_token_t()
        )
        let verifier = AcceptingPeerVerifier(fixedIdentity: badIdentity, requireEUID: true)
        let policy = PeerTrustPolicy(
            expectedCodeIdentifier: HostProtocol.relayCodeIdentifier,
            expectedEUID: euid
        )
        XCTAssertThrowsError(try verifier.verify(fd: 0, policy: policy)) { error in
            guard case .peerRejected? = error as? IPCError else {
                return XCTFail("expected peerRejected, got \(error)")
            }
        }

        let rejecting = RejectingPeerVerifier(reason: "unsigned peer")
        XCTAssertThrowsError(try rejecting.verify(fd: 0, policy: policy)) { error in
            guard case let .peerRejected(reason)? = error as? IPCError else {
                return XCTFail("expected peerRejected, got \(error)")
            }
            XCTAssertEqual(reason, "unsigned peer")
        }
    }

    func testProductionVerifierHasNoEnvBypass() {
        // Structural guarantee: SecurityPeerVerifier type exists and AcceptingPeerVerifier
        // is a separate test double — production default is SecurityPeerVerifier.
        let listenerDefault = HostListener(
            location: SocketLocation(
                directoryURL: tempRoot,
                socketURL: tempRoot.appendingPathComponent("s"),
                lockURL: tempRoot.appendingPathComponent("l")
            ),
            policy: .hostAcceptsRelay(relayExecutablePath: nil)
        )
        // Default verifier is SecurityPeerVerifier (no env switch consulted).
        XCTAssertTrue(listenerDefault.verifier is SecurityPeerVerifier)

        let req = SecurityPeerVerifier.requirementString(
            codeIdentifier: HostProtocol.relayCodeIdentifier,
            teamIdentifier: HostProtocol.teamIdentifier
        )
        XCTAssertTrue(req.contains(HostProtocol.relayCodeIdentifier))
        XCTAssertTrue(req.contains(HostProtocol.teamIdentifier))
        XCTAssertTrue(req.contains("anchor apple generic"))
    }

    // MARK: - Helpers

    private func readAll(fd: Int32, expected: Int) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while data.count < expected {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            data.append(buf, count: n)
        }
        return data
    }
}
