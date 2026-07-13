import Foundation
import ApplicationServices
import ComputerUseCore
import AccessibilityEngine

/// The live `ActionElement` backed by a real `AXUIElement` and the `AXClient`
/// extraction layer. This is the **impure** conformance; it is never exercised by
/// the permission-free unit tests (those use fakes). All AX work goes through
/// `AXClient` (public Apple APIs only).
public final class AXActionElement: ActionElement {
    private let handle: AXElementHandle
    private let client: AXClient

    private var axElement: AXUIElement { handle.element }

    public init(handle: AXElementHandle, client: AXClient) {
        self.handle = handle
        self.client = client
    }

    public convenience init(element: AXUIElement, client: AXClient) {
        self.init(handle: AXElementHandle(element), client: client)
    }

    // MARK: - ActionElement

    public var isLive: Bool { handle.isLive }

    public var role: String? { client.role(of: axElement) }

    public func actionNames() -> [String] { client.actionNames(of: axElement) }

    public func perform(_ action: String) throws {
        try client.performAction(axElement, action)
    }

    public func isSettable(_ attribute: String) -> Bool {
        client.isSettable(axElement, attribute)
    }

    public func snapshot(_ attribute: String) -> String? {
        guard let value = try? client.copyAttribute(axElement, attribute) else { return nil }
        return Self.stringify(value)
    }

    public func writeValue(_ value: ActionValue) throws {
        let cf: CFTypeRef
        switch value {
        case let .string(string):
            cf = string as CFString
        case let .number(number):
            cf = NSNumber(value: number)
        case let .boolean(flag):
            cf = (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        }
        try client.setAttribute(axElement, AXActionName.value, value: cf)
    }

    public func writeSelectedRange(location: Int, length: Int) throws {
        var range = CFRange(location: location, length: length)
        guard let axValue = AXValueCreate(.cfRange, &range) else {
            throw CUError.internalError(detail: "failed to create AXValue for CFRange")
        }
        try client.setAttribute(axElement, AXActionName.selectedTextRange, value: axValue)
    }

    public func element(for attribute: String) -> ActionElement? {
        guard let child = client.copyElement(axElement, attribute) else { return nil }
        return AXActionElement(element: child, client: client)
    }

    public func children() -> [ActionElement] {
        client.children(of: axElement).map { AXActionElement(element: $0, client: client) }
    }

    /// v1.5 (§18.5/§18.6): best-effort set `AXFocused = true` when settable. Never throws —
    /// focusing is advisory; a faulted or unsettable write just returns `false`.
    public func setKeyboardFocus() -> Bool {
        guard client.isSettable(axElement, AXActionName.focused) else { return false }
        do {
            try client.setAttribute(axElement, AXActionName.focused, value: kCFBooleanTrue)
            return true
        } catch {
            return false
        }
    }

    /// v1.5 (§18.6): whether this element (or a descendant) holds the owning app's keyboard
    /// focus. Reads the application's `AXFocusedUIElement` once and compares it to this element,
    /// then — bounded — walks the focused element's `AXParent` chain to detect the descendant
    /// case. Best-effort: any unreadable step yields `false`.
    public func holdsKeyboardFocus() -> Bool {
        guard let pid = try? client.pid(of: axElement) else { return false }
        let appElement = client.applicationElement(pid: pid)
        guard let focused = client.copyElement(appElement, AXActionName.focusedUIElement) else { return false }
        if CFEqual(focused, axElement) { return true }
        // Descendant case: walk up from the focused element to this one (bounded, mirrors the
        // AXTreeBuilder depth ceiling so a pathological chain cannot spin).
        var current: AXUIElement? = client.copyElement(focused, AXActionName.parent)
        var depth = 0
        while let node = current, depth < 64 {
            if CFEqual(node, axElement) { return true }
            current = client.copyElement(node, AXActionName.parent)
            depth += 1
        }
        return false
    }

    // MARK: - Helpers

    /// Stringify an AX attribute value for change comparison / numeric parsing.
    /// Booleans → `0`/`1`; numbers → shortest round-tripping decimal; strings verbatim.
    static func stringify(_ value: CFTypeRef) -> String? {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0"
        }
        if let number = value as? NSNumber {
            return shortestDecimal(number)
        }
        if let string = value as? String {
            return string
        }
        return nil
    }

    static func shortestDecimal(_ number: NSNumber) -> String {
        let objcType = String(cString: number.objCType)
        if objcType == "f" || objcType == "d" {
            let d = number.doubleValue
            if d == d.rounded(), abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        }
        if objcType == "c" || objcType == "B" {
            return number.boolValue ? "1" : "0"
        }
        return number.stringValue
    }
}
