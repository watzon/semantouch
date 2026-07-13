import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A single application candidate the resolver reasons over. This is the internal
/// value model; `toSummary()` projects it to the wire `AppSummary`.
public struct AppRecord: Equatable, Sendable {
    public var bundleId: String?
    public var displayName: String
    public var path: String?
    public var pid: Int32?
    public var isRunning: Bool
    public var windows: Int

    public init(
        bundleId: String?,
        displayName: String,
        path: String?,
        pid: Int32?,
        isRunning: Bool,
        windows: Int
    ) {
        self.bundleId = bundleId
        self.displayName = displayName
        self.path = path
        self.pid = pid
        self.isRunning = isRunning
        self.windows = windows
    }

    /// Project to the wire summary. `id` falls back bundle id → path → `pid:<pid>`.
    public func toSummary() -> AppSummary {
        let id: String
        if let bundleId {
            id = bundleId
        } else if let path {
            id = path
        } else if let pid {
            id = "pid:\(pid)"
        } else {
            id = "unknown"
        }
        return AppSummary(
            id: id,
            displayName: displayName,
            path: path,
            pid: pid.map(Int.init),
            isRunning: isRunning,
            windows: windows,
            lastUsedAt: nil
        )
    }
}

/// The data source the resolver reads. Abstracted so resolution is fully
/// unit-testable without permissions or a live workspace.
public protocol AppEnvironment {
    /// All known apps (running and installed), deduplicated so a running app and
    /// its installed bundle appear once.
    func allApps() -> [AppRecord]
    /// The record for a specific running process, if any.
    func app(forPID pid: Int32) -> AppRecord?
    /// Whether an absolute path currently exists on disk.
    func pathExists(_ path: String) -> Bool
}

/// Resolves an `app` string to a single application per PROTOCOL §10.1.
public struct AppResolver {
    public let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Convenience resolver backed by the live macOS workspace.
    public static func system() -> AppResolver {
        AppResolver(environment: SystemAppEnvironment())
    }

    /// Resolve `app` to one application. Rules are tried in order and resolution
    /// stops at the first that yields a match (§10.1):
    ///
    /// 0. `pid:<n>` → that process.
    /// 1. exact bundle id (case-insensitive).
    /// 2. exact absolute `.app` path that exists on disk.
    /// 3. exact localized display name.
    /// 4. unique case-insensitive display-name match.
    ///
    /// More than one candidate at a name rule → `ambiguous_app`; nothing → `app_not_found`.
    public func resolve(_ query: String) -> Result<AppRecord, CUError> {
        // Rule 0: explicit pid.
        if let pid = Self.parsePIDQuery(query) {
            if let record = environment.app(forPID: pid) {
                return .success(record)
            }
            return .failure(.appNotFound(query: query))
        }

        let apps = environment.allApps()

        // Rule 1: exact bundle id (case-insensitive).
        let byBundle = apps.filter { record in
            guard let bundleId = record.bundleId else { return false }
            return bundleId.caseInsensitiveCompare(query) == .orderedSame
        }
        if let result = Self.settle(byBundle, query: query) { return result }

        // Rule 2: exact absolute .app path that exists on disk.
        if query.hasPrefix("/"), query.hasSuffix(".app"), environment.pathExists(query) {
            if let match = apps.first(where: { $0.path == query }) {
                return .success(match)
            }
            // On disk but not in the catalog: synthesize a minimal record.
            return .success(Self.synthesize(fromPath: query))
        }

        // Rule 3: exact localized display name.
        let byExactName = apps.filter { $0.displayName == query }
        if let result = Self.settle(byExactName, query: query) { return result }

        // Rule 4: unique case-insensitive display-name match.
        let byCaseInsensitiveName = apps.filter {
            $0.displayName.caseInsensitiveCompare(query) == .orderedSame
        }
        if let result = Self.settle(byCaseInsensitiveName, query: query) { return result }

        return .failure(.appNotFound(query: query))
    }

    // MARK: - Helpers

    /// Reduce a rule's matches: 0 → continue (nil), 1 → success, >1 → ambiguous.
    static func settle(_ matches: [AppRecord], query: String) -> Result<AppRecord, CUError>? {
        switch matches.count {
        case 0:
            return nil
        case 1:
            return .success(matches[0])
        default:
            return .failure(.ambiguousApp(query: query, candidates: matches.map { $0.toSummary() }))
        }
    }

    /// Parse a `^pid:[0-9]+$` query to its pid, else `nil`.
    static func parsePIDQuery(_ query: String) -> Int32? {
        guard query.hasPrefix("pid:") else { return nil }
        let digits = query.dropFirst(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(digits)
    }

    /// Build a minimal record from a `.app` path (rule 2, uncatalogued bundle).
    static func synthesize(fromPath path: String) -> AppRecord {
        let last = (path as NSString).lastPathComponent
        let display = last.hasSuffix(".app") ? String(last.dropLast(4)) : last
        return AppRecord(
            bundleId: nil,
            displayName: display,
            path: path,
            pid: nil,
            isRunning: false,
            windows: 0
        )
    }
}

// MARK: - System-backed environment

/// `AppEnvironment` over the live macOS workspace: running apps from `NSWorkspace`,
/// installed apps from a shallow scan of the standard application directories.
/// Uses public APIs only.
public struct SystemAppEnvironment: AppEnvironment {
    /// Standard application directories scanned for installed bundles (non-recursive
    /// beyond the listed Utilities folders).
    public static let applicationDirectories: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    public init() {}

    public func allApps() -> [AppRecord] {
        var byKey: [String: AppRecord] = [:]
        var order: [String] = []

        func key(for record: AppRecord) -> String {
            if let bundleId = record.bundleId { return "bundle:" + bundleId.lowercased() }
            if let path = record.path { return "path:" + path.lowercased() }
            if let pid = record.pid { return "pid:\(pid)" }
            return "name:" + record.displayName.lowercased()
        }

        func add(_ record: AppRecord) {
            let k = key(for: record)
            if var existing = byKey[k] {
                // Merge: prefer the running instance's pid/path/bundle id.
                if existing.pid == nil { existing.pid = record.pid }
                if !existing.isRunning { existing.isRunning = existing.isRunning || record.isRunning }
                if existing.path == nil { existing.path = record.path }
                if existing.bundleId == nil { existing.bundleId = record.bundleId }
                existing.windows = max(existing.windows, record.windows)
                byKey[k] = existing
            } else {
                byKey[k] = record
                order.append(k)
            }
        }

        #if canImport(AppKit)
        // `.regular` (normal foreground apps) plus `.accessory` (LSUIElement menu-bar
        // / background apps that can still own automatable windows). `.prohibited`
        // (pure daemons) is excluded.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular || app.activationPolicy == .accessory {
            let name = app.localizedName
                ?? app.bundleURL.map { ($0.lastPathComponent as NSString).deletingPathExtension }
                ?? "Unknown"
            add(AppRecord(
                bundleId: app.bundleIdentifier,
                displayName: name,
                path: app.bundleURL?.path,
                pid: app.processIdentifier,
                isRunning: true,
                windows: 0 // TODO(CaptureEngine): count capturable windows.
            ))
        }
        #endif

        let fileManager = FileManager.default
        for directory in Self.applicationDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (directory as NSString).appendingPathComponent(entry)
                let bundleId = Bundle(path: path)?.bundleIdentifier
                let displayed = fileManager.displayName(atPath: path)
                let display = displayed.hasSuffix(".app") ? String(displayed.dropLast(4)) : displayed
                add(AppRecord(
                    bundleId: bundleId,
                    displayName: display,
                    path: path,
                    pid: nil,
                    isRunning: false,
                    windows: 0
                ))
            }
        }

        return order.compactMap { byKey[$0] }
    }

    public func app(forPID pid: Int32) -> AppRecord? {
        #if canImport(AppKit)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let name = app.localizedName
            ?? app.bundleURL.map { ($0.lastPathComponent as NSString).deletingPathExtension }
            ?? "Unknown"
        return AppRecord(
            bundleId: app.bundleIdentifier,
            displayName: name,
            path: app.bundleURL?.path,
            pid: pid,
            isRunning: true,
            windows: 0
        )
        #else
        return nil
        #endif
    }

    public func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
