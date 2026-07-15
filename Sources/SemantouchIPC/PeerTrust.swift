import Foundation
import Darwin
import Security

// MARK: - Peer identity

/// Kernel- and code-signing identity of a connected peer.
public struct PeerIdentity: Equatable, Sendable {
    public var euid: uid_t
    public var egid: gid_t
    public var pid: pid_t
    public var auditToken: audit_token_t
    public var codeIdentifier: String?
    public var teamIdentifier: String?
    public var executablePath: String?

    public init(
        euid: uid_t,
        egid: gid_t,
        pid: pid_t,
        auditToken: audit_token_t,
        codeIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        executablePath: String? = nil
    ) {
        self.euid = euid
        self.egid = egid
        self.pid = pid
        self.auditToken = auditToken
        self.codeIdentifier = codeIdentifier
        self.teamIdentifier = teamIdentifier
        self.executablePath = executablePath
    }
}

/// Expected peer policy for mutual authentication.
public struct PeerTrustPolicy: Equatable, Sendable {
    public var expectedCodeIdentifier: String
    public var expectedTeamIdentifier: String
    public var expectedExecutablePath: String?
    /// When set, peer euid must equal this value (normally the local euid).
    public var expectedEUID: uid_t

    public init(
        expectedCodeIdentifier: String,
        expectedTeamIdentifier: String = HostProtocol.teamIdentifier,
        expectedExecutablePath: String? = nil,
        expectedEUID: uid_t = geteuid()
    ) {
        self.expectedCodeIdentifier = expectedCodeIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedExecutablePath = expectedExecutablePath
        self.expectedEUID = expectedEUID
    }

    /// Host-side policy: peer must be the nested relay.
    public static func hostAcceptsRelay(
        relayExecutablePath: String?,
        euid: uid_t = geteuid()
    ) -> PeerTrustPolicy {
        PeerTrustPolicy(
            expectedCodeIdentifier: HostProtocol.relayCodeIdentifier,
            expectedTeamIdentifier: HostProtocol.teamIdentifier,
            expectedExecutablePath: relayExecutablePath,
            expectedEUID: euid
        )
    }

    /// Relay-side policy: peer must be the app host.
    public static func relayAcceptsHost(
        hostExecutablePath: String?,
        euid: uid_t = geteuid()
    ) -> PeerTrustPolicy {
        PeerTrustPolicy(
            expectedCodeIdentifier: HostProtocol.hostCodeIdentifier,
            expectedTeamIdentifier: HostProtocol.teamIdentifier,
            expectedExecutablePath: hostExecutablePath,
            expectedEUID: euid
        )
    }
}

// MARK: - Verifier protocol

/// Injectable peer verification. Production uses `SecurityPeerVerifier`.
/// Unit tests supply fakes. **There is no environment-variable bypass in
/// production code paths.**
public protocol PeerVerifying: Sendable {
    /// Inspect and validate the peer on `fd` against `policy`.
    /// Throws `IPCError.peerRejected` / credential errors on failure.
    func verify(fd: Int32, policy: PeerTrustPolicy) throws -> PeerIdentity
}

// MARK: - Credential extraction seam

public struct PeerCredentialSeam: Sendable {
    public var getpeereid: (Int32) throws -> (uid_t, gid_t)
    public var auditToken: (Int32) throws -> audit_token_t
    public var pidFromAuditToken: (audit_token_t) -> pid_t
    public var codeInfo: (audit_token_t) throws -> (identifier: String, team: String, path: String)

    public init(
        getpeereid: @escaping (Int32) throws -> (uid_t, gid_t),
        auditToken: @escaping (Int32) throws -> audit_token_t,
        pidFromAuditToken: @escaping (audit_token_t) -> pid_t,
        codeInfo: @escaping (audit_token_t) throws -> (identifier: String, team: String, path: String)
    ) {
        self.getpeereid = getpeereid
        self.auditToken = auditToken
        self.pidFromAuditToken = pidFromAuditToken
        self.codeInfo = codeInfo
    }

    public static let live = PeerCredentialSeam(
        getpeereid: { fd in
            var uid: uid_t = 0
            var gid: gid_t = 0
            if Darwin.getpeereid(fd, &uid, &gid) != 0 {
                throw IPCError.peerCredentialsUnavailable
            }
            return (uid, gid)
        },
        auditToken: { fd in
            var token = audit_token_t()
            var len = socklen_t(MemoryLayout<audit_token_t>.size)
            let rc = withUnsafeMutablePointer(to: &token) { tokenPtr -> Int32 in
                tokenPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<audit_token_t>.size) { bytes in
                    getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, bytes, &len)
                }
            }
            if rc != 0 {
                throw IPCError.peerAuditTokenUnavailable
            }
            return token
        },
        pidFromAuditToken: { token in
            // XNU/libbsm layout: pid lives at audit_token_t.val[5].
            // Implemented inline to avoid an extra libbsm link dependency.
            pid_t(bitPattern: token.val.5)
        },
        codeInfo: { token in
            try SecurityPeerVerifier.copyCodeInfo(auditToken: token)
        }
    )
}

// MARK: - Production verifier

/// Production peer verifier: getpeereid + LOCAL_PEERTOKEN + Security.framework
/// designated-requirement validation. **No environment bypass.**
public struct SecurityPeerVerifier: PeerVerifying {
    public let credentials: PeerCredentialSeam
    /// Optional precompiled requirement string override (tests may inject).
    public let requirementOverride: String?

    public init(
        credentials: PeerCredentialSeam = .live,
        requirementOverride: String? = nil
    ) {
        self.credentials = credentials
        self.requirementOverride = requirementOverride
    }

    public func verify(fd: Int32, policy: PeerTrustPolicy) throws -> PeerIdentity {
        let (euid, egid) = try credentials.getpeereid(fd)
        if euid != policy.expectedEUID {
            throw IPCError.peerRejected(
                reason: "peer euid \(euid) != expected \(policy.expectedEUID)"
            )
        }

        let token = try credentials.auditToken(fd)
        let pid = credentials.pidFromAuditToken(token)

        let info: (identifier: String, team: String, path: String)
        do {
            info = try credentials.codeInfo(token)
        } catch let error as IPCError {
            throw error
        } catch {
            throw IPCError.peerCodeUntrusted(reason: String(describing: error))
        }

        if info.identifier != policy.expectedCodeIdentifier {
            throw IPCError.peerRejected(
                reason: "code identifier \(info.identifier) != \(policy.expectedCodeIdentifier)"
            )
        }
        if info.team != policy.expectedTeamIdentifier {
            throw IPCError.peerRejected(
                reason: "team \(info.team) != \(policy.expectedTeamIdentifier)"
            )
        }
        if let expectedPath = policy.expectedExecutablePath {
            // Compare standardized paths to tolerate trailing-slash differences.
            let left = URL(fileURLWithPath: info.path).standardizedFileURL.path
            let right = URL(fileURLWithPath: expectedPath).standardizedFileURL.path
            if left != right {
                throw IPCError.peerRejected(
                    reason: "executable path \(info.path) != \(expectedPath)"
                )
            }
        }

        // Live designated-requirement check against the dynamic code object.
        try Self.validateRequirement(
            auditToken: token,
            codeIdentifier: policy.expectedCodeIdentifier,
            teamIdentifier: policy.expectedTeamIdentifier,
            requirementOverride: requirementOverride
        )

        return PeerIdentity(
            euid: euid,
            egid: egid,
            pid: pid,
            auditToken: token,
            codeIdentifier: info.identifier,
            teamIdentifier: info.team,
            executablePath: info.path
        )
    }

    /// Build the designated requirement string for a Developer ID peer.
    public static func requirementString(
        codeIdentifier: String,
        teamIdentifier: String
    ) -> String {
        // Anchor to Developer ID Application + Team + identifier.
        // CDHash is intentionally NOT pinned (legitimate updates change it).
        """
        identifier "\(codeIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\(teamIdentifier)" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
        """
    }

    public static func copyCodeInfo(
        auditToken: audit_token_t
    ) throws -> (identifier: String, team: String, path: String) {
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes: [CFString: Any] = [
            kSecGuestAttributeAudit: tokenData
        ]
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            [],
            &code
        )
        guard status == errSecSuccess, let code else {
            throw IPCError.peerCodeUntrusted(
                reason: "SecCodeCopyGuestWithAttributes failed (\(status))"
            )
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw IPCError.peerCodeUntrusted(
                reason: "SecCodeCopyStaticCode failed (\(staticStatus))"
            )
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard infoStatus == errSecSuccess, let infoCF = infoCF as? [String: Any] else {
            throw IPCError.peerCodeUntrusted(
                reason: "SecCodeCopySigningInformation failed (\(infoStatus))"
            )
        }

        let identifier = (infoCF[kSecCodeInfoIdentifier as String] as? String) ?? ""
        // Team identifier key.
        let team = (infoCF[kSecCodeInfoTeamIdentifier as String] as? String) ?? ""

        var path = ""
        if let url = infoCF[kSecCodeInfoMainExecutable as String] as? URL {
            path = url.path
        } else if let pathString = infoCF[kSecCodeInfoMainExecutable as String] as? String {
            path = pathString
        } else {
            // Fallback: path of the static code.
            var codeURL: CFURL?
            if SecCodeCopyPath(staticCode, [], &codeURL) == errSecSuccess,
               let codeURL = codeURL as URL? {
                path = codeURL.path
            }
        }

        if identifier.isEmpty {
            throw IPCError.peerCodeUntrusted(reason: "missing code identifier")
        }
        if team.isEmpty {
            throw IPCError.peerCodeUntrusted(reason: "missing team identifier")
        }
        if path.isEmpty {
            throw IPCError.peerCodeUntrusted(reason: "missing executable path")
        }
        return (identifier, team, path)
    }

    public static func validateRequirement(
        auditToken: audit_token_t,
        codeIdentifier: String,
        teamIdentifier: String,
        requirementOverride: String? = nil
    ) throws {
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes: [CFString: Any] = [
            kSecGuestAttributeAudit: tokenData
        ]
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            [],
            &code
        )
        guard status == errSecSuccess, let code else {
            throw IPCError.peerCodeUntrusted(
                reason: "SecCodeCopyGuestWithAttributes failed (\(status))"
            )
        }

        let requirementText = requirementOverride
            ?? requirementString(codeIdentifier: codeIdentifier, teamIdentifier: teamIdentifier)
        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        )
        guard reqStatus == errSecSuccess, let requirement else {
            throw IPCError.peerCodeUntrusted(
                reason: "SecRequirementCreateWithString failed (\(reqStatus))"
            )
        }

        let check = SecCodeCheckValidity(code, [], requirement)
        if check != errSecSuccess {
            throw IPCError.peerCodeUntrusted(
                reason: "SecCodeCheckValidity failed (\(check))"
            )
        }
    }
}

// MARK: - Always-accept verifier (tests / ad-hoc local only)

/// Test double that accepts any peer matching the euid policy (or all peers
/// when `requireEUID` is false). **Must never be wired into release host/relay
/// entry points.** There is no environment variable that selects this in
/// production code.
public struct AcceptingPeerVerifier: PeerVerifying {
    public var fixedIdentity: PeerIdentity?
    public var requireEUID: Bool
    public var rejectReason: String?

    public init(
        fixedIdentity: PeerIdentity? = nil,
        requireEUID: Bool = true,
        rejectReason: String? = nil
    ) {
        self.fixedIdentity = fixedIdentity
        self.requireEUID = requireEUID
        self.rejectReason = rejectReason
    }

    public func verify(fd: Int32, policy: PeerTrustPolicy) throws -> PeerIdentity {
        if let rejectReason {
            throw IPCError.peerRejected(reason: rejectReason)
        }
        if let fixedIdentity {
            if requireEUID && fixedIdentity.euid != policy.expectedEUID {
                throw IPCError.peerRejected(
                    reason: "peer euid \(fixedIdentity.euid) != expected \(policy.expectedEUID)"
                )
            }
            return fixedIdentity
        }
        // Minimal identity from getpeereid only (no code-signing).
        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) != 0 {
            throw IPCError.peerCredentialsUnavailable
        }
        if requireEUID && uid != policy.expectedEUID {
            throw IPCError.peerRejected(
                reason: "peer euid \(uid) != expected \(policy.expectedEUID)"
            )
        }
        return PeerIdentity(
            euid: uid,
            egid: gid,
            pid: 0,
            auditToken: audit_token_t()
        )
    }
}

/// Verifier that always rejects with a fixed reason (negative-path tests).
public struct RejectingPeerVerifier: PeerVerifying {
    public var reason: String

    public init(reason: String = "test rejection") {
        self.reason = reason
    }

    public func verify(fd: Int32, policy: PeerTrustPolicy) throws -> PeerIdentity {
        throw IPCError.peerRejected(reason: reason)
    }
}
