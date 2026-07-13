import Foundation
import ApplicationServices

/// Web-content accessibility enablement (docs/PROTOCOL.md §18.1).
///
/// Chromium/Electron applications render their web-content AX subtree lazily: until an
/// assistive client announces itself they expose only browser chrome. Both gates are
/// **public** AX attributes on the target **application** element, settable with the
/// already-granted Accessibility permission (no new TCC): Electron reads
/// `AXManualAccessibility`, Chromium reads `AXEnhancedUserInterface`. `get_app_state`
/// best-effort flips both to `true` once per session, and resets **only** the ones this
/// server itself flipped (never a pre-existing `true`, e.g. VoiceOver's).
///
/// The decision logic is pure over the `WebAXAppElement` seam so it is unit-tested with a
/// fake — no live app element or Accessibility grant (mirrors `WorkspaceControlling`). The
/// live conformance (`LiveWebAXAppElement`) is the impure adapter over `AXUIElement`.
public enum WebContentAccessibility {
    /// The web-content enablement attributes, in a fixed attempt order (§18.1).
    public static let attributes: [String] = [
        AXAttr.manualAccessibility,
        AXAttr.enhancedUserInterface,
    ]

    /// The outcome of setting one attribute (§18.1). `unsupported` (e.g.
    /// `attributeUnsupported`/`noValue`) is a **silent** no-op for a non-web app; `faulted`
    /// is a genuine AX error that warrants a re-attempt on the next snapshot.
    public enum SetOutcome: Equatable, Sendable {
        case set
        case unsupported
        case faulted
    }

    /// The per-application AX attribute operations enablement needs. Injected so the
    /// enable/reset decision is exercised without a live app element or grant.
    public protocol WebAXAppElement: AnyObject {
        /// Current boolean value of `attribute`, or `nil` when unsupported/absent.
        func currentBool(_ attribute: String) -> Bool?
        /// Set `attribute` to `value`, reporting whether it took, was unsupported, or faulted.
        func setBool(_ attribute: String, _ value: Bool) -> SetOutcome
    }

    /// The result of an enable attempt.
    public struct EnableResult: Equatable, Sendable {
        /// Attributes this call transitioned `false`/absent → `true` (i.e. **this server**
        /// flipped them). Only these are reset on `end_app_session`/shutdown.
        public var newlyEnabled: [String]
        /// Attributes already `true` before this call (never reset by us).
        public var alreadyEnabled: [String]
        /// Attributes that could not be set (unsupported/absent — non-web app no-op).
        public var unsupported: [String]
        /// Whether any write **faulted** (a real AX error) → re-attempt next snapshot (§18.1).
        public var faulted: Bool

        public init(
            newlyEnabled: [String] = [],
            alreadyEnabled: [String] = [],
            unsupported: [String] = [],
            faulted: Bool = false
        ) {
            self.newlyEnabled = newlyEnabled
            self.alreadyEnabled = alreadyEnabled
            self.unsupported = unsupported
            self.faulted = faulted
        }

        /// Whether at least one attribute transitioned to enabled (§18.1: this snapshot then
        /// settles with the loading deadline and gains the `web_content_enabled` warning).
        public var didEnableAny: Bool { !newlyEnabled.isEmpty }
    }

    /// Best-effort enable pass over the seam (§18.1). Reads each attribute's current value,
    /// sets it to `true` only when not already `true`, and classifies the result. Pure.
    public static func enable(_ element: WebAXAppElement) -> EnableResult {
        var result = EnableResult()
        for attribute in attributes {
            if element.currentBool(attribute) == true {
                result.alreadyEnabled.append(attribute)
                continue
            }
            switch element.setBool(attribute, true) {
            case .set: result.newlyEnabled.append(attribute)
            case .unsupported: result.unsupported.append(attribute)
            case .faulted: result.faulted = true
            }
        }
        return result
    }

    /// Best-effort reset of the given (server-flipped) attributes to `false` (§18.1).
    /// Called from `end_app_session` and process shutdown; never touches an attribute this
    /// server did not flip. Pure over the seam; outcomes are ignored (best-effort).
    public static func reset(_ element: WebAXAppElement, attributes flipped: [String]) {
        for attribute in flipped {
            _ = element.setBool(attribute, false)
        }
    }
}

/// The live `WebAXAppElement` over an application `AXUIElement` (§18.1). Impure — reads via
/// `AXClient` and writes with a raw `AXUIElementSetAttributeValue` so the exact `AXError`
/// distinguishes an unsupported attribute (silent, non-web app) from a genuine fault
/// (re-attempt next snapshot). Never unit-tested; the pure logic above is.
public final class LiveWebAXAppElement: WebContentAccessibility.WebAXAppElement {
    private let element: AXUIElement
    private let client: AXClient

    public init(element: AXUIElement, client: AXClient) {
        self.element = element
        self.client = client
    }

    public func currentBool(_ attribute: String) -> Bool? {
        client.copyBool(element, attribute)
    }

    public func setBool(_ attribute: String, _ value: Bool) -> WebContentAccessibility.SetOutcome {
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, cfValue)
        switch err {
        case .success:
            return .set
        case .attributeUnsupported, .noValue, .parameterizedAttributeUnsupported:
            return .unsupported
        default:
            // Chromium quirk (live finding, macOS 26 / Aside at.studio.AsideBrowser):
            // setting `AXEnhancedUserInterface` on a Chromium shell returns
            // `.cannotComplete` (-25208) even though the write TAKES EFFECT — the
            // attribute re-reads `true` and the web-content tree materializes. An
            // error return therefore cannot be trusted as "did not take": verify by
            // re-read, and classify as `.set` when the attribute now holds the
            // requested value (§18.1 — this drives the `web_content_enabled` warning,
            // the forced settle, and the reset-on-end bookkeeping; misclassifying it
            // as `.faulted` suppresses all three and leaves the flip unreset).
            if client.copyBool(element, attribute) == value {
                return .set
            }
            return .faulted
        }
    }
}
