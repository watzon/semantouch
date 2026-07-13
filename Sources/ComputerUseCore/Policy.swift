import Foundation

/// How aggressively an action may disturb the user's foreground.
public enum InterferencePolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case backgroundOnly = "background-only"
    case allowBriefFocus = "allow-brief-focus"
    case foregroundTakeover = "foreground-takeover"
}

/// Per-application policy gate for computer-use access.
///
/// The default is deliberately permissive: no application is denied unless the
/// operator names it in `SEMANTOUCH_DENIED_APPS`. The denylist applies to both reads
/// and mutations, and matches exact, case-insensitive application identity tokens
/// (bundle identifier, display name, full path, or the path's last component).
public struct PolicyEngine: Sendable {
    public var defaultInterference: InterferencePolicy
    public let appDenylist: Set<String>

    public init(
        defaultInterference: InterferencePolicy = .backgroundOnly,
        appDenylist: Set<String> = []
    ) {
        self.defaultInterference = defaultInterference
        self.appDenylist = Set(appDenylist.map { $0.lowercased() })
    }

    /// Parse a comma-separated denylist from the process environment.
    /// Empty entries are ignored and matching is case-insensitive.
    public static func appDenylistFrom(
        environment: [String: String]
    ) -> Set<String> {
        guard let raw = environment["SEMANTOUCH_DENIED_APPS"] else {
            return []
        }
        var result: Set<String> = []
        for item in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                result.insert(normalized)
            }
        }
        return result
    }

    /// Construct the process-wide policy from `SEMANTOUCH_DENIED_APPS`.
    public static func system(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PolicyEngine {
        PolicyEngine(appDenylist: appDenylistFrom(environment: environment))
    }

    /// Return whether an application matches the operator-configured denylist.
    public func isAppDenied(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> Bool {
        !identityTokens(bundleId: bundleId, displayName: displayName, path: path)
            .isDisjoint(with: appDenylist)
    }

    /// Read-only access uses the same operator denylist as mutation access.
    public func readDenialReason(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> PolicyDenyReason? {
        isAppDenied(bundleId: bundleId, displayName: displayName, path: path)
            ? .appDenied
            : nil
    }

    /// Mutations are permitted unless the target matches the operator denylist.
    public func mutationDenialReason(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> PolicyDenyReason? {
        isAppDenied(bundleId: bundleId, displayName: displayName, path: path)
            ? .appDenied
            : nil
    }

    private func identityTokens(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> Set<String> {
        var tokens: Set<String> = []
        for value in [bundleId, displayName, path] {
            if let value, !value.isEmpty {
                tokens.insert(value.lowercased())
            }
        }
        if let path, !path.isEmpty {
            tokens.insert(URL(fileURLWithPath: path).lastPathComponent.lowercased())
        }
        return tokens
    }
}
