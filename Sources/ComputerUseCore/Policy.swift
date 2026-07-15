import Foundation

/// How aggressively an action may disturb the user's foreground.
public enum InterferencePolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case backgroundOnly = "background-only"
    case allowBriefFocus = "allow-brief-focus"
    case foregroundTakeover = "foreground-takeover"
}

/// Per-application policy gate for computer-use access.
///
/// By default, common password managers are denied. Operators can augment that
/// set with `SEMANTOUCH_DENIED_APPS` (comma-separated exact identity tokens).
/// Setting `SEMANTOUCH_ALLOW_SENSITIVE_APPS` to exactly `1` disables the built-in
/// sensitive denylist; operator deny entries still apply. Callers that pass an
/// explicit `appDenylist` keep that exact set for deterministic tests and
/// configuration. Matching is case-insensitive against bundle identifier,
/// display name, full path, or the path's last component — never substrings.
public struct PolicyEngine: Sendable {
    public var defaultInterference: InterferencePolicy
    public let appDenylist: Set<String>

    /// Canonical, case-insensitive identity tokens for password managers denied
    /// by default. Exact tokens only: stable bundle IDs plus common display and
    /// `.app` basenames — no broad substring matching.
    public static let defaultSensitiveAppDenylist: Set<String> = Set(
        [
            // 1Password
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "1Password",
            "1Password 7",
            "1Password.app",
            "1Password 7.app",
            // Bitwarden
            "com.bitwarden.desktop",
            "Bitwarden",
            "Bitwarden.app",
            // Dashlane
            "com.dashlane.dashlanephonefinal",
            "com.dashlane.Dashlane",
            "Dashlane",
            "Dashlane.app",
            // LastPass
            "com.lastpass.LastPass",
            "com.lastpass.lastpassmacdesktop",
            "LastPass",
            "LastPass.app",
            // NordPass
            "com.nordsec.nordpass",
            "NordPass",
            "NordPass.app",
            // Proton Pass
            "me.proton.pass.electron",
            "me.proton.pass.catalyst",
            "Proton Pass",
            "Proton Pass.app",
        ].map { $0.lowercased() }
    )

    /// - Parameter appDenylist: Exact denylist to use. When omitted, the built-in
    ///   sensitive-app denylist is applied. Passing a value (including `[]`) uses
    ///   that set as-is with no automatic merge.
    public init(
        defaultInterference: InterferencePolicy = .backgroundOnly,
        appDenylist: Set<String> = PolicyEngine.defaultSensitiveAppDenylist
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

    /// Whether built-in sensitive-app protection is disabled for this environment.
    /// Only the exact value `1` opts out; any other or missing value keeps built-ins.
    public static func allowsSensitiveApps(
        environment: [String: String]
    ) -> Bool {
        environment["SEMANTOUCH_ALLOW_SENSITIVE_APPS"] == "1"
    }

    /// Construct the process-wide policy from the environment.
    ///
    /// `SEMANTOUCH_DENIED_APPS` always augments the active denylist. Built-in
    /// password-manager protection is included unless
    /// `SEMANTOUCH_ALLOW_SENSITIVE_APPS` is exactly `1`.
    public static func system(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PolicyEngine {
        let operatorDeny = appDenylistFrom(environment: environment)
        if allowsSensitiveApps(environment: environment) {
            return PolicyEngine(appDenylist: operatorDeny)
        }
        return PolicyEngine(appDenylist: defaultSensitiveAppDenylist.union(operatorDeny))
    }

    /// Return whether an application matches the configured denylist.
    public func isAppDenied(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> Bool {
        !identityTokens(bundleId: bundleId, displayName: displayName, path: path)
            .isDisjoint(with: appDenylist)
    }

    /// Read-only access uses the same denylist as mutation access.
    public func readDenialReason(
        bundleId: String?,
        displayName: String?,
        path: String?
    ) -> PolicyDenyReason? {
        isAppDenied(bundleId: bundleId, displayName: displayName, path: path)
            ? .appDenied
            : nil
    }

    /// Mutations are permitted unless the target matches the denylist.
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
