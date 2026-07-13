import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore

/// Walks a window's live AX hierarchy into a pruned, pure `UINode` tree
/// (docs/PROTOCOL.md §7). This is the **impure** extraction step: it
/// reads the AX API through `AXClient`, converts global points to window points,
/// assigns stable `e<N>` ids through `StableElementTable`, and returns a value tree
/// the pure `AXTreeRenderer` can serialize.
///
/// Pruning (docs/PROTOCOL.md §7.4):
/// - drop meaningless **empty structural groups** (`AXGroup`/`AXUnknown`/… with no
///   title/value/desc/actions and no surviving children) but keep any that still
///   have surviving children — they are explanatory ancestors;
/// - **associate label elements with controls**: a static-text leaf that another
///   element references via `AXTitleUIElement` is dropped (its text renders on the
///   labeled control's `title`);
/// - **keep disabled controls** (state is meaningful);
/// - **deterministic child ordering** — children stay in `AXChildren` order (§7.4).
///
/// Robustness: per-node attribute reads degrade gracefully (a failed attribute is
/// skipped, never the subtree — `AXClient` typed reads return `nil` on failure). A
/// generous depth cap and a hard node ceiling bound the walk; the final node/byte
/// truncation and omission marker are the renderer's job (§7.5).
public struct AXTreeBuilder {
    public struct Options: Equatable, Sendable {
        /// Maximum tree depth walked (root is depth 0). Nodes at the cap are kept as
        /// leaves; their children are dropped and the build is marked truncated.
        public var maxDepth: Int
        /// Hard safety ceiling on nodes built. Well above the renderer's node cap so
        /// the renderer (600) is the effective limiter for normal UIs.
        public var buildNodeCeiling: Int

        public init(
            maxDepth: Int = 64,
            buildNodeCeiling: Int = AccessibilityEngine.hardMaxNodes
        ) {
            self.maxDepth = maxDepth
            self.buildNodeCeiling = buildNodeCeiling
        }

        public static let `default` = Options()
    }

    public struct BuildResult: Equatable, Sendable {
        /// The single depth-0 root (the window element).
        public var root: UINode
        /// Element id of the focused element when it lies within this tree.
        public var focusedElementId: String?
        /// Total nodes in the pruned tree (`root.nodeCount`).
        public var totalNodes: Int
        /// Whether the depth cap or node ceiling dropped nodes during the walk.
        public var truncatedDuringBuild: Bool
        /// v1.5 (§18.4): document identity read from the principal `AXWebArea` (largest
        /// frame area; ties → first in pre-order) when the built tree contains one and at
        /// least one of `url`/`title` is readable. Nil otherwise.
        public var document: AppState.WindowInfo.DocumentInfo?

        public init(
            root: UINode,
            focusedElementId: String?,
            totalNodes: Int,
            truncatedDuringBuild: Bool,
            document: AppState.WindowInfo.DocumentInfo? = nil
        ) {
            self.root = root
            self.focusedElementId = focusedElementId
            self.totalNodes = totalNodes
            self.truncatedDuringBuild = truncatedDuringBuild
            self.document = document
        }
    }

    private let client: AXClient
    private let options: Options

    public init(client: AXClient = AXClient(), options: Options = .default) {
        self.client = client
        self.options = options
    }

    /// Build the pruned `UINode` tree for `windowElement`.
    ///
    /// - `windowFrameGlobal`: the window's frame in **global points** (§9); every
    ///   node frame is converted to window points relative to its origin.
    /// - `focusedElement`: the application's focused element (usually read from the
    ///   app element's `AXFocusedUIElement`); used to mark `focused=true` and set
    ///   `focusedElementId`. Pass `nil` when unknown.
    /// - `table`: the session's stable id table. `beginPass`/`endPass` bracket the
    ///   id assignment so ids for vanished elements are retired.
    public func build(
        windowElement: AXUIElement,
        windowFrameGlobal: Rect,
        focusedElement: AXUIElement? = nil,
        table: StableElementTable
    ) -> BuildResult {
        let ctx = Context(
            client: client,
            options: options,
            windowFrame: windowFrameGlobal,
            focusedElement: focusedElement,
            table: table
        )

        // Pass 0: collect elements used as another element's title (label targets).
        var visited = 0
        ctx.collectLabelTargets(windowElement, depth: 0, counter: &visited)

        // Pass A: build the pruned raw tree (no ids yet — pruning may drop nodes).
        let rootRole = client.role(of: windowElement) ?? "AXWindow"
        let rawRoot = ctx.buildRaw(
            windowElement,
            role: rootRole,
            depth: 0,
            parentHash: ElementFingerprint.rootParentHash,
            ordinal: 0
        )

        // Pass B: assign ids pre-order (parent before children) so numbering matches
        // traversal, and resolve the focused element id.
        table.beginPass()
        let root: UINode
        if let rawRoot {
            root = ctx.assignIds(rawRoot)
        } else {
            // A window should never fully prune; synthesize a minimal root so the
            // contract (single depth-0 root) always holds.
            let fingerprint = ElementFingerprint(
                role: rootRole, subrole: nil, axIdentifier: nil,
                parentHash: ElementFingerprint.rootParentHash, siblingOrdinal: 0,
                normalizedTitle: ""
            )
            let id = table.assign(handle: AXElementHandle(windowElement), fingerprint: fingerprint)
            root = UINode(
                id: id, role: rootRole,
                frame: Rect(x: 0, y: 0, width: windowFrameGlobal.width, height: windowFrameGlobal.height)
            )
        }
        table.endPass()

        // §18.4: expose the principal web area's document identity (omitted when no web
        // area was retained or neither URL nor title is readable).
        let document: AppState.WindowInfo.DocumentInfo?
        if let web = ctx.principalWebArea, web.url != nil || web.title != nil {
            document = AppState.WindowInfo.DocumentInfo(url: web.url, title: web.title)
        } else {
            document = nil
        }

        return BuildResult(
            root: root,
            focusedElementId: ctx.focusedElementId,
            totalNodes: root.nodeCount,
            truncatedDuringBuild: ctx.truncated,
            document: document
        )
    }

    // MARK: - Element identity

    /// Hashable wrapper for `AXUIElement` identity (`CFEqual`/`CFHash`), used to
    /// track label targets and match the focused element.
    struct AXRef: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (lhs: AXRef, rhs: AXRef) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    // MARK: - Intermediate node

    /// A built element before id assignment: display fields plus the AX reference
    /// and fingerprint the id table needs.
    private struct RawNode {
        let element: AXUIElement
        let fingerprint: ElementFingerprint
        let role: String
        let subrole: String?
        let title: String?
        let value: String?
        let description: String?
        let placeholder: String?
        let axIdentifier: String?
        let enabled: Bool
        let focusedMatch: Bool
        let focusedAttr: Bool
        let selected: Bool
        let frame: Rect?
        let actions: [String]
        let settableAttributes: [String]
        var children: [RawNode]
    }

    // MARK: - Build context

    /// Mutable per-build state, isolated so the recursion stays readable.
    private final class Context {
        let client: AXClient
        let options: Options
        let windowFrame: Rect
        let focusedElement: AXUIElement?
        let table: StableElementTable

        var labelTargets: Set<AXRef> = []
        var builtCount = 0
        var truncated = false
        var focusedElementId: String?
        var focusedMatched = false
        /// v1.5 §18.4: the largest-area `AXWebArea` retained so far (ties → first pre-order),
        /// with its document URL/title. Nil until the first web area is seen.
        var principalWebArea: (area: Double, url: String?, title: String?)?

        /// Structural roles that carry no meaning when empty.
        static let structuralRoles: Set<String> = [
            "AXGroup", "AXUnknown", "AXGenericElement",
            "AXLayoutArea", "AXLayoutItem", "AXSplitGroup",
        ]
        /// Candidate settable attributes recorded for Phase-2 mutation.
        static let settableCandidates: [String] = [
            AXAttr.value, AXAttr.focused, AXAttr.selectedText,
            AXAttr.selectedTextRange, AXAttr.selected,
        ]

        init(
            client: AXClient,
            options: Options,
            windowFrame: Rect,
            focusedElement: AXUIElement?,
            table: StableElementTable
        ) {
            self.client = client
            self.options = options
            self.windowFrame = windowFrame
            self.focusedElement = focusedElement
            self.table = table
        }

        // MARK: Pass 0

        func collectLabelTargets(_ element: AXUIElement, depth: Int, counter: inout Int) {
            guard depth <= options.maxDepth, counter < options.buildNodeCeiling else { return }
            counter += 1
            if let target = client.copyElement(element, AXAttr.titleUIElement) {
                labelTargets.insert(AXRef(target))
            }
            guard depth < options.maxDepth else { return }
            for child in client.children(of: element) {
                collectLabelTargets(child, depth: depth + 1, counter: &counter)
                if counter >= options.buildNodeCeiling { break }
            }
        }

        // MARK: Pass A

        func buildRaw(_ element: AXUIElement, role: String, depth: Int, parentHash: Int, ordinal: Int) -> RawNode? {
            guard depth <= options.maxDepth else { truncated = true; return nil }
            builtCount += 1
            guard builtCount <= options.buildNodeCeiling else { truncated = true; return nil }

            let subrole = client.subrole(of: element)
            let axIdentifier = client.copyString(element, AXAttr.identifier)
            let title = coarseCap(resolveTitle(element))
            let value = coarseCap(resolveValue(element))
            let description = coarseCap(nonEmpty(client.copyString(element, AXAttr.description)))
            let placeholder = coarseCap(nonEmpty(client.copyString(element, AXAttr.placeholder)))
            let enabled = client.copyBool(element, AXAttr.enabled) ?? true
            let focusedAttr = client.copyBool(element, AXAttr.focused) ?? false
            let focusedMatch = focusedElement.map { CFEqual($0, element) } ?? false
            let selected = client.copyBool(element, AXAttr.selected) ?? false
            let frame = resolveFrame(element)
            let actions = client.actionNames(of: element)
            let settable = Context.settableCandidates.filter { client.isSettable(element, $0) }

            let fingerprint = ElementFingerprint(
                role: role,
                subrole: subrole,
                axIdentifier: axIdentifier,
                parentHash: parentHash,
                siblingOrdinal: ordinal,
                normalizedTitle: ElementFingerprint.normalizeTitle(title)
            )

            // Prune label static-text leaves whose text is shown on a labeled control.
            if role == "AXStaticText",
               labelTargets.contains(AXRef(element)),
               !focusedAttr, !focusedMatch {
                return nil
            }

            // Build children in AX order; track per-role sibling ordinals.
            var children: [RawNode] = []
            if depth < options.maxDepth {
                var ordinals: [String: Int] = [:]
                for child in client.children(of: element) {
                    if builtCount >= options.buildNodeCeiling { truncated = true; break }
                    let childRole = client.role(of: child) ?? "AXUnknown"
                    let childOrdinal = ordinals[childRole, default: 0]
                    ordinals[childRole] = childOrdinal + 1
                    if let raw = buildRaw(
                        child,
                        role: childRole,
                        depth: depth + 1,
                        parentHash: fingerprint.stableHash,
                        ordinal: childOrdinal
                    ) {
                        children.append(raw)
                    }
                }
            } else if !client.children(of: element).isEmpty {
                truncated = true
            }

            // Drop meaningless empty structural groups, keep explanatory ancestors.
            if Context.structuralRoles.contains(role),
               children.isEmpty,
               isEmpty(title), isEmpty(value), isEmpty(placeholder), isEmpty(description),
               actions.isEmpty, !focusedAttr, !focusedMatch, !selected {
                return nil
            }

            // §18.4: record web areas (retained nodes only) so `document` can expose the
            // principal one. Reads `AXURL` lazily — only when this becomes the new principal.
            considerWebArea(element, role: role, title: title, description: description, frame: frame)

            return RawNode(
                element: element,
                fingerprint: fingerprint,
                role: role,
                subrole: subrole,
                title: title,
                value: value,
                description: description,
                placeholder: placeholder,
                axIdentifier: axIdentifier,
                enabled: enabled,
                focusedMatch: focusedMatch,
                focusedAttr: focusedAttr,
                selected: selected,
                frame: frame,
                actions: actions,
                settableAttributes: settable,
                children: children
            )
        }

        // MARK: Pass B

        func assignIds(_ raw: RawNode) -> UINode {
            let id = table.assign(handle: AXElementHandle(raw.element), fingerprint: raw.fingerprint)
            if raw.focusedMatch {
                focusedElementId = StableElementTable.idString(id) // CFEqual match wins
                focusedMatched = true
            } else if raw.focusedAttr, !focusedMatched, focusedElementId == nil {
                focusedElementId = StableElementTable.idString(id)
            }
            let children = raw.children.map { assignIds($0) }
            return UINode(
                id: id,
                role: raw.role,
                subrole: raw.subrole,
                title: raw.title,
                value: raw.value,
                description: raw.description,
                placeholder: raw.placeholder,
                axIdentifier: raw.axIdentifier,
                enabled: raw.enabled,
                focused: raw.focusedMatch || raw.focusedAttr,
                selected: raw.selected,
                frame: raw.frame,
                actions: raw.actions,
                settableAttributes: raw.settableAttributes,
                children: children
            )
        }

        // MARK: Extraction helpers

        /// Title = `AXTitle` if nonempty, else the `AXValue`/`AXTitle` of the element
        /// referenced by `AXTitleUIElement` (§7.2).
        private func resolveTitle(_ element: AXUIElement) -> String? {
            if let t = nonEmpty(client.copyString(element, AXAttr.title)) { return t }
            if let label = client.copyElement(element, AXAttr.titleUIElement) {
                if let v = nonEmpty(client.copyString(label, AXAttr.value)) { return v }
                if let t = nonEmpty(client.copyString(label, AXAttr.title)) { return t }
            }
            return nil
        }

        /// Stringify `AXValue` (§7.2): strings verbatim; booleans/toggles as `0`/`1`;
        /// numbers as the shortest round-tripping decimal. Non-scalar values → `nil`.
        private func resolveValue(_ element: AXUIElement) -> String? {
            guard let raw = try? client.copyAttribute(element, AXAttr.value) else { return nil }
            if CFGetTypeID(raw) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((raw as! CFBoolean)) ? "1" : "0"
            }
            if let number = raw as? NSNumber {
                return Self.shortestDecimal(number)
            }
            if let string = raw as? String {
                return nonEmpty(string)
            }
            return nil
        }

        /// v1.5 §18.4: consider one node as a web-area document source. Tracks the largest
        /// frame area (ties → first pre-order, since only a strictly-larger area replaces the
        /// incumbent) and reads `AXURL` lazily. `title`/`description` are the already-resolved
        /// display strings; the document title is the nonempty title, else description.
        private func considerWebArea(_ element: AXUIElement, role: String, title: String?, description: String?, frame: Rect?) {
            guard role == "AXWebArea" else { return }
            let area = frame.map { max(0, $0.width) * max(0, $0.height) } ?? 0
            if let existing = principalWebArea, area <= existing.area { return }
            let url = client.copyURLString(element, AXAttr.url)
            let docTitle = nonEmpty(title) ?? nonEmpty(description)
            principalWebArea = (area: area, url: url, title: docTitle)
        }

        /// Frame converted from global points to window points (§9).
        private func resolveFrame(_ element: AXUIElement) -> Rect? {
            guard let global = client.frame(of: element) else { return nil }
            return Rect(
                x: Double(global.origin.x) - windowFrame.x,
                y: Double(global.origin.y) - windowFrame.y,
                width: Double(global.size.width),
                height: Double(global.size.height)
            )
        }

        private func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }

        /// Coarse memory bound on an extracted string: the renderer applies the exact
        /// 256-byte per-field cap (§7.5), but a pathological `AXValue` (a megabyte of
        /// text) should not be carried in the model. Cut on a character boundary well
        /// above the render cap so this never changes emitted output.
        private func coarseCap(_ s: String?) -> String? {
            guard let s else { return nil }
            let limit = AccessibilityEngine.maxFieldBytes * 8 // 2 KB, >> the 256 render cap
            guard s.utf8.count > limit else { return s }
            var result = ""
            var bytes = 0
            for ch in s {
                let b = String(ch).utf8.count
                if bytes + b > limit { break }
                result.append(ch)
                bytes += b
            }
            return result
        }

        private func isEmpty(_ s: String?) -> Bool {
            s?.isEmpty ?? true
        }

        static func shortestDecimal(_ number: NSNumber) -> String {
            let objcType = String(cString: number.objCType)
            if objcType == "f" || objcType == "d" {
                let d = number.doubleValue
                if d == d.rounded(), abs(d) < 1e15 {
                    return String(Int64(d)) // whole double → integer form
                }
                return String(d) // Swift's shortest round-tripping decimal
            }
            if objcType == "c" || objcType == "B" {
                return number.boolValue ? "1" : "0"
            }
            return number.stringValue
        }
    }
}
