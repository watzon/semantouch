import Foundation
import ComputerUseCore
import CaptureEngine

/// Builds the `list_apps` payload (§4.1): **running and installed** applications
/// with a count of capturable windows.
///
/// Enumeration reuses `SystemAppEnvironment.allApps()` — the same source the app
/// resolver uses (§10.1) — so `list_apps` and `get_app_state` see a consistent
/// universe: running apps from `NSWorkspace` merged with installed `.app` bundles
/// scanned from the standard application directories, deduped so a running app and
/// its installed bundle appear once (the running instance wins the merge). It MUST
/// NOT scan recent-use databases. Window counts come from `CGWindowListCopyWindowInfo`,
/// which is permission-free (no Screen Recording grant needed to count normal
/// on-screen windows per pid) and are overlaid onto the running records; an
/// installed-but-not-running app reports `isRunning:false`, no `pid`, and `windows:0`.
public enum AppLister {
    /// Enumerate running + installed apps into `AppSummary` records, sorted by display
    /// name then pid then id for a stable, deterministic ordering.
    public static func listApps() -> [AppSummary] {
        // Merged running + installed universe (public APIs only; no recent-use scan).
        let records = SystemAppEnvironment().allApps()

        // One CGWindowList pass; count normal, visible windows per owner pid. Only
        // meaningful for running apps (installed-not-running have no windows).
        var windowsByPID: [Int32: Int] = [:]
        for window in WindowCatalog.cgWindows(includeOffscreen: false) where window.isNormalVisible {
            windowsByPID[window.ownerPID, default: 0] += 1
        }

        let summaries = records.map { record -> AppSummary in
            var summary = record.toSummary() // isRunning / pid / path / id per §4.1
            summary.windows = record.pid.map { windowsByPID[$0] ?? 0 } ?? 0
            summary.lastUsedAt = nil // never emitted in Phase 1
            return summary
        }

        return summaries.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            if (lhs.pid ?? 0) != (rhs.pid ?? 0) {
                return (lhs.pid ?? 0) < (rhs.pid ?? 0)
            }
            return lhs.id < rhs.id
        }
    }
}
