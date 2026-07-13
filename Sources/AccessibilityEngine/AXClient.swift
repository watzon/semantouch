import Foundation
import ApplicationServices
import CoreGraphics
import ComputerUseCore

/// Raw AX attribute / value-type name strings.
///
/// Written as literals rather than the SDK `kAX…` constants so the wrapper does not
/// depend on which constants a given SDK re-exports to Swift; the on-the-wire
/// attribute names are stable ("AXRole", "AXValue", …).
enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let value = "AXValue"
    static let description = "AXDescription"
    static let placeholder = "AXPlaceholderValue"
    static let identifier = "AXIdentifier"
    static let enabled = "AXEnabled"
    static let focused = "AXFocused"
    static let selected = "AXSelected"
    static let children = "AXChildren"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let frame = "AXFrame"
    static let titleUIElement = "AXTitleUIElement"
    static let focusedUIElement = "AXFocusedUIElement"
    static let mainWindow = "AXMainWindow"
    static let focusedWindow = "AXFocusedWindow"
    static let windows = "AXWindows"
    static let window = "AXWindow"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
    // v1.5 §18.1: web-content accessibility enablement attributes on the app element.
    static let manualAccessibility = "AXManualAccessibility"     // Electron
    static let enhancedUserInterface = "AXEnhancedUserInterface"  // Chromium
    // v1.5 §18.4: the principal web area's document URL.
    static let url = "AXURL"
}

/// A live `AXUIElement`, conforming to `ElementHandle` so `StableElementTable` can
/// test it for validity with public APIs only.
public final class AXElementHandle: ElementHandle {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    /// Live iff a cheap attribute read does not report `.invalidUIElement`. A
    /// genuinely valid element returns `.success` (or `.noValue` when it lacks a
    /// role); only a destroyed element yields `.invalidUIElement`.
    public var isLive: Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, AXAttr.role as CFString, &value)
        return err != .invalidUIElement
    }
}

/// A thin, typed wrapper over the `AXUIElement` C API (docs/PROTOCOL.md §7). This is the
/// **impure** extraction layer; nothing here is exercised by the permission-free
/// unit tests. Higher layers build pure `UINode`s from these reads and render them.
///
/// CF ownership: every `…Copy…` call follows the Create Rule (returns +1). The
/// modern Swift overlay binds each result into a managed `CFTypeRef?` out-parameter,
/// so ARC balances the retain automatically — equivalent to `takeRetainedValue()`
/// on the old `Unmanaged` form. No manual `CFRelease` is required or correct here.
public struct AXClient {
    public init() {}

    // MARK: - Application / identity

    /// The top-level accessibility element for a process.
    public func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// The owning process id of an element.
    public func pid(of element: AXUIElement) throws -> pid_t {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(element, &pid)
        guard err == .success else { throw Self.mapError(err) }
        return pid
    }

    /// `AXRole`, or `nil` when unavailable.
    public func role(of element: AXUIElement) -> String? {
        copyString(element, AXAttr.role)
    }

    /// `AXSubrole`, or `nil` when absent.
    public func subrole(of element: AXUIElement) -> String? {
        copyString(element, AXAttr.subrole)
    }

    // MARK: - Attribute copies

    /// Copy a single attribute value. Returns `nil` for the "absent" errors
    /// (`.noValue`, `.attributeUnsupported`); throws (mapped) for real faults.
    ///
    /// The returned `CFTypeRef?` is ARC-managed (see the type-level CF ownership note).
    public func copyAttribute(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch err {
        case .success:
            return value
        case .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported:
            return nil
        default:
            throw Self.mapError(err)
        }
    }

    /// Copy several attributes in one round trip. Returns one entry per requested
    /// attribute in the same order; an unreadable / error-placeholder entry is `nil`.
    public func copyMultipleAttributes(_ element: AXUIElement, _ attributes: [String]) throws -> [CFTypeRef?] {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(), // no stop-on-error: keep placeholders
            &out
        )
        guard err == .success, let array = out as? [AnyObject] else {
            throw Self.mapError(err)
        }
        return array.map { entry -> CFTypeRef? in
            // Missing values arrive as an AXValue wrapping an AXError; treat as nil.
            if CFGetTypeID(entry) == AXValueGetTypeID(),
               AXValueGetType(entry as! AXValue) == .axError {
                return nil
            }
            return entry
        }
    }

    /// Action names the element exposes, e.g. `["AXPress"]`.
    public func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(element, &names)
        guard err == .success, let list = names as? [String] else { return [] }
        return list
    }

    /// Whether an attribute is settable on the element (`AXUIElementIsAttributeSettable`).
    public func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    // MARK: - Typed convenience reads

    /// A string attribute; `nil` when absent or not a string.
    public func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = try? copyAttribute(element, attribute) else { return nil }
        if let s = value as? String { return s }
        // Some values arrive as NSNumber/CFNumber; not a string.
        return nil
    }

    /// A URL-valued attribute (e.g. `AXURL`) as its absolute string form; `nil` when
    /// absent or not URL-shaped (§18.4). `AXURL` arrives as a CFURL (toll-free bridged to
    /// `URL`); some elements expose it as a plain string, which is passed through verbatim.
    public func copyURLString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = try? copyAttribute(element, attribute) else { return nil }
        if let url = value as? URL { return url.absoluteString }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let cfURL = value as! CFURL
            if let string = CFURLGetString(cfURL) as String? { return string }
        }
        if let string = value as? String { return string }
        return nil
    }

    /// A boolean attribute; `nil` when absent or not a boolean.
    public func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = try? copyAttribute(element, attribute) else { return nil }
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// A child element list (`AXChildren`) in AX order.
    public func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = try? copyAttribute(element, AXAttr.children) else { return [] }
        return elements(from: value)
    }

    /// A single element-valued attribute (e.g. `AXTitleUIElement`, `AXFocusedUIElement`).
    public func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = try? copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// An element-array attribute (e.g. `AXWindows`) in AX order. Empty when the
    /// attribute is absent or not an element array. Unlike `children(of:)` this reads
    /// an arbitrary named attribute so the window-resolution layer can enumerate
    /// `AXWindows` without conflating it with `AXChildren`.
    public func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = try? copyAttribute(element, attribute) else { return [] }
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { entry in
            CFGetTypeID(entry) == AXUIElementGetTypeID() ? (entry as! AXUIElement) : nil
        }
    }

    /// The application's top-level windows (`AXWindows`), in AX order.
    public func windows(of application: AXUIElement) -> [AXUIElement] {
        elementArray(application, AXAttr.windows)
    }

    /// The application's AX focused window (`AXFocusedWindow`), if any.
    public func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        copyElement(application, AXAttr.focusedWindow)
    }

    /// The application's AX main window (`AXMainWindow`), if any.
    public func mainWindow(of application: AXUIElement) -> AXUIElement? {
        copyElement(application, AXAttr.mainWindow)
    }

    /// The application's AX focused UI element (`AXFocusedUIElement`), if any.
    public func focusedUIElement(of application: AXUIElement) -> AXUIElement? {
        copyElement(application, AXAttr.focusedUIElement)
    }

    /// The element's frame in **global points** (top-left origin). Prefers `AXFrame`;
    /// falls back to composing `AXPosition` + `AXSize`. `nil` when neither resolves.
    public func frame(of element: AXUIElement) -> CGRect? {
        // `try?` of an `Optional` return flattens to a single optional, so one bind
        // unwraps both the throw and the nil-value cases.
        if let value = try? copyAttribute(element, AXAttr.frame),
           CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect) {
                return rect
            }
        }
        guard
            let posValue = try? copyAttribute(element, AXAttr.position),
            let sizeValue = try? copyAttribute(element, AXAttr.size),
            CFGetTypeID(posValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Mutation (CLI probes now; Phase 2 later)

    /// Perform a named action (`AXUIElementPerformAction`), e.g. `"AXPress"`.
    public func performAction(_ element: AXUIElement, _ action: String) throws {
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else { throw Self.mapError(err) }
    }

    /// Set an attribute value (`AXUIElementSetAttributeValue`).
    public func setAttribute(_ element: AXUIElement, _ attribute: String, value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard err == .success else { throw Self.mapError(err) }
    }

    // MARK: - Helpers

    /// Extract `[AXUIElement]` from a copied attribute value that is a CFArray.
    private func elements(from value: CFTypeRef?) -> [AXUIElement] {
        guard let value, let array = value as? [AnyObject] else { return [] }
        return array.compactMap { entry in
            CFGetTypeID(entry) == AXUIElementGetTypeID() ? (entry as! AXUIElement) : nil
        }
    }

    // MARK: - Error mapping

    /// Map an `AXError` to a `CUError` (§6). Only `.apiDisabled` carries a clean
    /// wire meaning without element/session context — it means the Accessibility
    /// grant is missing. Element-scoped faults (`unsupported_action`,
    /// `stale_element`) are re-created with their context by the calling layer;
    /// here everything else degrades to `internal_error` with a stable slug.
    public static func mapError(_ err: AXError) -> CUError {
        switch err {
        case .apiDisabled:
            return .permissionDenied(
                permission: .accessibility,
                helperPath: helperPath(),
                remediation: accessibilityRemediation()
            )
        case .success:
            return .internalError(detail: "ax_success_unexpected")
        default:
            return .internalError(detail: "ax_\(err.rawValue)")
        }
    }

    /// Best-effort path of the running helper binary, for `permission_denied` data.
    static func helperPath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "semantouch"
    }

    /// Generic Accessibility remediation naming the running binary.
    static func accessibilityRemediation() -> [String] {
        let path = helperPath()
        return [
            "Open System Settings › Privacy & Security › Accessibility.",
            "Enable access for \"\(path)\".",
            "Restart the helper so the new grant takes effect.",
        ]
    }
}
