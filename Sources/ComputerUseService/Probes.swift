import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore
import AccessibilityEngine
import CaptureEngine

/// A CLI-only spike-driver failure (Phase 0). Distinct from the wire `CUError`s
/// because probes are not MCP tools; they exercise the engines directly.
public enum ProbeError: Error, CustomStringConvertible {
    case notRunning(app: String)
    case elementNotFound(identifier: String)

    public var description: String {
        switch self {
        case let .notRunning(app):
            return "application \"\(app)\" is not running"
        case let .elementNotFound(identifier):
            return "no element with AXIdentifier \"\(identifier)\" was found"
        }
    }
}

/// Phase 0 spike drivers exposed through the CLI (`probe …`). These are **not** MCP
/// tools: `press` / `set-value` drive `AXPress` / `AXValue` directly through
/// `AXClient`, and `capture` / `ax-tree` exercise the read pipeline without the
/// session/element-id machinery. They target elements by `AXIdentifier`.
public enum Probe {
    /// `probe capture` result.
    public struct CaptureResult: Sendable {
        public let path: String
        public let byteCount: Int
        public let width: Int
        public let height: Int
        public let windowNumber: Int
    }

    // MARK: - capture

    /// Capture the target window of `app` to a PNG file (`--out`). Requires the
    /// Screen Recording grant; never falls back to a display screenshot.
    public static func capture(
        app: String,
        outPath: String,
        context: ServiceContext
    ) async throws -> CaptureResult {
        let (record, pid, appElement) = try resolveRunning(app: app, context: context)
        try gateRead(record: record, context: context, app: app)
        let selection = try WindowResolution.resolve(
            appElement: appElement, pid: pid, app: app,
            explicitWindowId: nil, client: context.axClient
        ).selection
        let scale = AppStateBuilder.backingScale(forGlobalRect: selection.frameGlobal)

        let snapshot = try await WindowCatalog.snapshot()
        guard let scWindow = snapshot.shareableWindow(number: selection.windowNumber) else {
            throw CUError.uncapturableWindow(app: app, windowId: selection.windowNumber, reason: .stale)
        }
        let image = try await WindowCapture.captureImage(
            scWindow: scWindow, framePoints: selection.frameGlobal,
            scale: scale, app: app, windowNumber: selection.windowNumber
        )
        let encoded = try ScreenshotEncoder.encodePNG(image)
        try encoded.data.write(to: URL(fileURLWithPath: outPath))
        return CaptureResult(
            path: outPath, byteCount: encoded.byteCount,
            width: encoded.width, height: encoded.height,
            windowNumber: selection.windowNumber
        )
    }

    // MARK: - ax-tree

    /// Build and render the `semantouch-ax-tree-v1` text for the target window of `app`.
    public static func axTree(app: String, context: ServiceContext) throws -> String {
        let (record, pid, appElement) = try resolveRunning(app: app, context: context)
        try gateRead(record: record, context: context, app: app)
        let selection = try WindowResolution.resolve(
            appElement: appElement, pid: pid, app: app,
            explicitWindowId: nil, client: context.axClient
        ).selection
        let table = StableElementTable() // probe: throwaway ids, not a session.
        let focused = context.axClient.focusedUIElement(of: appElement)
        let result = AXTreeBuilder(client: context.axClient).build(
            windowElement: selection.axWindow,
            windowFrameGlobal: selection.frameGlobal,
            focusedElement: focused,
            table: table
        )
        return AXTreeRenderer.render(result.root).text
    }

    // MARK: - press

    /// `AXPress` the element whose `AXIdentifier` is `identifier` (Phase 0 spike).
    ///
    /// Gated by the same operator-configured app denylist as the MCP mutation path.
    /// The gate runs before the probe performs any AX mutation.
    public static func press(app: String, identifier: String, context: ServiceContext) throws {
        let (record, _, appElement) = try resolveRunning(app: app, context: context)
        try gateMutation(record: record, context: context, app: app)
        guard let element = findElement(withIdentifier: identifier, root: appElement, client: context.axClient) else {
            throw ProbeError.elementNotFound(identifier: identifier)
        }
        try context.axClient.performAction(element, "AXPress")
    }

    // MARK: - set-value

    /// Set the `AXValue` of the element whose `AXIdentifier` is `identifier` to the
    /// string `value` (Phase 0 spike). Gated by the mutation policy (§13.5), like
    /// `press`.
    public static func setValue(app: String, identifier: String, value: String, context: ServiceContext) throws {
        let (record, _, appElement) = try resolveRunning(app: app, context: context)
        try gateMutation(record: record, context: context, app: app)
        guard let element = findElement(withIdentifier: identifier, root: appElement, client: context.axClient) else {
            throw ProbeError.elementNotFound(identifier: identifier)
        }
        try context.axClient.setAttribute(element, "AXValue", value: value as CFTypeRef)
    }

    // MARK: - Shared helpers

    /// Enforce the operator-configured app denylist before a read-only probe walks a
    /// target's AX tree or captures its window. Mutation probes use the same denylist.
    static func gateRead(record: AppRecord, context: ServiceContext, app: String) throws {
        if let reason = context.policyEngine.readDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: app, tool: nil)
        }
    }

    /// Enforce the operator-configured app denylist before a probe mutates an app.
    /// A denied app throws `policy_denied` before any AX call.
    static func gateMutation(record: AppRecord, context: ServiceContext, app: String) throws {
        if let reason = context.policyEngine.mutationDenialReason(
            bundleId: record.bundleId,
            displayName: record.displayName,
            path: record.path
        ) {
            throw CUError.policyDenied(reason: reason, app: app, tool: nil)
        }
    }

    /// Resolve a running app to `(record, pid, appElement)`, preflighting the
    /// Accessibility grant so a missing grant is a clean `permission_denied`.
    static func resolveRunning(app: String, context: ServiceContext) throws -> (record: AppRecord, pid: pid_t, element: AXUIElement) {
        guard AXIsProcessTrusted() else {
            let path = DoctorService.helperPath()
            throw CUError.permissionDenied(
                permission: .accessibility, helperPath: path,
                remediation: [
                    "Grant Accessibility: open System Settings › Privacy & Security › Accessibility and enable \"\(path)\".",
                    "Restart \"\(path)\" so the new grant takes effect.",
                ]
            )
        }
        let record: AppRecord
        switch AppResolver.system().resolve(app) {
        case let .success(resolved): record = resolved
        case let .failure(error): throw error
        }
        guard let pid = record.pid else { throw ProbeError.notRunning(app: app) }
        return (record, pid, context.axClient.applicationElement(pid: pid))
    }

    /// Depth-first search from an application element for the first descendant whose
    /// `AXIdentifier` equals `identifier`. Bounded to avoid runaway trees.
    static func findElement(
        withIdentifier identifier: String,
        root: AXUIElement,
        client: AXClient,
        limit: Int = 50_000
    ) -> AXUIElement? {
        var stack = client.children(of: root)
        var visited = 0
        while let element = stack.popLast(), visited < limit {
            visited += 1
            if client.copyString(element, "AXIdentifier") == identifier {
                return element
            }
            stack.append(contentsOf: client.children(of: element))
        }
        return nil
    }
}
