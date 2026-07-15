import Foundation
import ComputerUseCore
import CaptureEngine
#if canImport(CoreServices)
import CoreServices
#endif

// MARK: - AppLister seams (permission-free tests inject fakes)

/// Spotlight/Metadata lookup for one absolute `.app` path.
public protocol AppMetadataProviding: Sendable {
    /// Public metadata for `path`, when available.
    func metadata(forPath path: String) -> AppPathMetadata
}

/// Path-scoped Spotlight attributes used by `list_apps`.
public struct AppPathMetadata: Equatable, Sendable {
    public var lastUsedAt: Date?
    public var useCount: Int?

    public init(lastUsedAt: Date? = nil, useCount: Int? = nil) {
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }
}

/// Counts normal, visible windows for a running pid (permission-free CG path).
public protocol AppWindowCounting: Sendable {
    func visibleWindowCount(forPID pid: Int32) -> Int
}

/// Live Spotlight/Metadata provider (`MDItem` public APIs only).
///
/// `kMDItemUseCount` is a documented Spotlight attribute name but is not always
/// exported as a C symbol on current SDKs, so the live path uses the public
/// attribute string via a local CFString constant.
public struct SpotlightAppMetadata: AppMetadataProviding {
    /// Public Spotlight attribute name for launch/use frequency.
    /// Not always present as `kMDItemUseCount` in the SDK headers.
    private static let useCountAttribute = "kMDItemUseCount" as CFString

    public init() {}

    public func metadata(forPath path: String) -> AppPathMetadata {
        #if canImport(CoreServices)
        guard !path.isEmpty, let item = MDItemCreate(nil, path as CFString) else {
            return AppPathMetadata()
        }
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        let useCount: Int?
        if let number = MDItemCopyAttribute(item, Self.useCountAttribute) as? NSNumber {
            useCount = number.intValue
        } else {
            useCount = nil
        }
        return AppPathMetadata(lastUsedAt: lastUsed, useCount: useCount)
        #else
        return AppPathMetadata()
        #endif
    }
}

/// Live CGWindowList window counter (no Screen Recording grant required).
public struct CGAppWindowCounter: AppWindowCounting {
    public init() {}

    public func visibleWindowCount(forPID pid: Int32) -> Int {
        WindowCatalog.cgWindows(includeOffscreen: false)
            .filter { $0.ownerPID == pid && $0.isNormalVisible }
            .count
    }
}

/// Builds the `list_apps` payload (§4.1): **running and installed** applications
/// with a count of capturable windows and optional Spotlight recency/use rank.
///
/// Enumeration reuses `AppEnvironment.allApps()` — the same source the app
/// resolver uses (§10.1) — so `list_apps` and `get_app_state` see a consistent
/// universe: running apps from `NSWorkspace` merged with installed `.app` bundles
/// scanned from the standard application directories, deduped so a running app and
/// its installed bundle appear once (the running instance wins the merge).
///
/// Recency metadata is read only through the public Spotlight/Metadata APIs
/// (`MDItemCreate` + `kMDItemLastUsedDate` / `kMDItemUseCount`) against each known
/// app path. This is **not** a silent launch path: `AppLister` never activates,
/// opens, or recovers applications.
public enum AppLister {
    /// Enumerate running + installed apps into `AppSummary` records.
    ///
    /// Sort order is deterministic:
    /// 1. running apps first
    /// 2. more recent `lastUsedAt` first (unknown last)
    /// 3. higher `useCount` first (unknown last)
    /// 4. display name (case-insensitive)
    /// 5. pid, then id
    public static func listApps(
        environment: AppEnvironment = SystemAppEnvironment(),
        metadata: any AppMetadataProviding = SpotlightAppMetadata(),
        windows: any AppWindowCounting = CGAppWindowCounter()
    ) -> [AppSummary] {
        let records = environment.allApps()

        var enriched: [(summary: AppSummary, lastUsed: Date?, useCount: Int?)] = []
        enriched.reserveCapacity(records.count)

        for record in records {
            var summary = record.toSummary()
            if let pid = record.pid {
                summary.windows = windows.visibleWindowCount(forPID: pid)
            } else {
                summary.windows = 0
            }

            let meta = record.path.map { metadata.metadata(forPath: $0) } ?? AppPathMetadata()
            if let lastUsed = meta.lastUsedAt {
                summary.lastUsedAt = iso8601String(from: lastUsed)
            } else {
                summary.lastUsedAt = nil
            }
            summary.useCount = meta.useCount
            enriched.append((summary, meta.lastUsedAt, meta.useCount))
        }

        enriched.sort { lhs, rhs in
            // 1. Running first.
            if lhs.summary.isRunning != rhs.summary.isRunning {
                return lhs.summary.isRunning && !rhs.summary.isRunning
            }
            // 2. More recent last-used first; unknown last.
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r:
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            // 3. Higher use-count first; unknown last.
            switch (lhs.useCount, rhs.useCount) {
            case let (l?, r?) where l != r:
                return l > r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            // 4–6. Stable name / pid / id.
            let nameOrder = lhs.summary.displayName
                .localizedCaseInsensitiveCompare(rhs.summary.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if (lhs.summary.pid ?? 0) != (rhs.summary.pid ?? 0) {
                return (lhs.summary.pid ?? 0) < (rhs.summary.pid ?? 0)
            }
            return lhs.summary.id < rhs.summary.id
        }

        return enriched.map(\.summary)
    }

    /// ISO-8601 wire form for `AppSummary.lastUsedAt`.
    static func iso8601String(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
