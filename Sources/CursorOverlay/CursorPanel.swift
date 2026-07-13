import Foundation
import CoreGraphics
import QuartzCore
import ComputerUseCore

// Live overlay presentation. This is the ONLY impure, AppKit-bearing
// file in the module; everything above it (CursorArt / CursorAnimator / CursorController)
// is pure and tested. Nothing here gates action correctness — the panel is decorative and
// self-guards so the headless `mcp` server never creates a window when there is no GUI
// session.
//
// The cursor is a lifelike, flying arrow: it EASES to each
// target with a velocity-derived lean/skew/stretch (from the pure `CursorAnimator` motion
// model), draws the reference arrow tinted by the session identity colour with a white
// outline, and spawns an expanding, fading click ripple on each press. A main-thread
// display timer advances the motion model and redraws cheap CAShapeLayers; the timer parks
// itself the moment the motion settles, so an idle overlay costs nothing.
//
// Clean-room: the panel, the arrow outline, the ripple, and the motion feel are
// independently authored from Apple's PUBLIC AppKit/QuartzCore documentation. Nothing is
// copied from the OpenAI bundle.

#if canImport(AppKit)
import AppKit

// MARK: - Nonactivating overlay panel

/// A borderless, nonactivating, click-through overlay panel:
/// - `.borderless` + `.nonactivatingPanel` so clicking it never activates the app;
/// - `canBecomeKey` / `canBecomeMain` overridden to **false** (never steals key/main);
/// - `ignoresMouseEvents = true` (click-through; the system pointer is unaffected);
/// - floats above normal windows and joins all Spaces so it can track the target.
///
/// The panel NEVER moves the system pointer; it only draws a decorative cursor.
final class CursorPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // click-through; system pointer untouched.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let view = CursorView(frame: contentRect(forFrameRect: frame))
        contentView = view
        cursorView = view
    }

    private(set) weak var cursorView: CursorView?

    // Never key, never main — the overlay must not take focus from the user's work.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Cursor view (layer-hosted, independently-authored art)

/// Hosts the arrow and ripple layers and renders one motion frame. Layer-hosting (not
/// layer-backed) so we fully own the sublayers; `isGeometryFlipped` gives the sublayers a
/// TOP-LEFT origin so the model's panel-local points map straight through. The heavy work
/// per frame is rebuilding two small `CGPath`s — trivial for a 7-point arrow and a ring.
final class CursorView: NSView {
    /// The arrow: tinted fill + white outline + soft shadow.
    private let arrowLayer = CAShapeLayer()
    /// A small pool of ripple rings, reused across clicks.
    private var rippleLayers: [CAShapeLayer] = []
    /// On-screen art size multiplier for the arrow outline (points ≈ base × this). Sized to
    /// read as a normal system cursor — base outline is ~14.6×24.6, so ~0.62 gives a ~9×15 pt
    /// arrow.
    private let artScale: Double = 0.62

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true    // sublayers use top-left origin (+y down).

        arrowLayer.lineJoin = .round
        arrowLayer.lineCap = .round
        arrowLayer.strokeColor = NSColor.white.cgColor
        arrowLayer.lineWidth = 1.5
        arrowLayer.shadowColor = NSColor.black.cgColor
        arrowLayer.shadowOpacity = 0.28
        arrowLayer.shadowRadius = 1.4
        arrowLayer.shadowOffset = CGSize(width: 0, height: 0.5)
        layer?.addSublayer(arrowLayer)

        for _ in 0..<4 {
            let ring = CAShapeLayer()
            ring.fillColor = NSColor.clear.cgColor
            ring.lineWidth = 2.5
            ring.opacity = 0
            layer?.addSublayer(ring)
            rippleLayers.append(ring)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through at the view too.

    /// Render one motion frame (MAIN THREAD). Rebuilds the arrow path from the pose and
    /// updates the ripple rings; all inside a no-implicit-animation transaction so OUR
    /// per-frame motion is the only animation (Core Animation never adds its own tween).
    func render(color: CursorColor, frame: CursorRenderFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // The arrow reads as a dark, charcoal-tinted cursor (like a real pointer) that still
        // carries the thread's hue for per-session distinctness; the bright full identity
        // colour is reserved for the click ripple so a click visibly pops. Darken toward
        // charcoal while preserving the hue.
        let darken = 0.34
        let fill = CGColor(red: color.red * darken, green: color.green * darken,
                           blue: color.blue * darken, alpha: color.alpha)
        arrowLayer.fillColor = fill

        let pts = CursorArt.outlinePath(pose: frame.pose, artScale: artScale)
        let path = CGMutablePath()
        if let first = pts.first {
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
        }
        arrowLayer.path = path

        // Ripple rings: the model hands us up to a few live frames; show those, hide the rest.
        for (i, ring) in rippleLayers.enumerated() {
            if i < frame.ripples.count {
                let r = frame.ripples[i]
                let rect = CGRect(x: r.center.x - r.radius, y: r.center.y - r.radius,
                                  width: r.radius * 2, height: r.radius * 2)
                ring.path = CGPath(ellipseIn: rect, transform: nil)
                ring.strokeColor = CGColor(red: color.red, green: color.green, blue: color.blue, alpha: r.alpha)
                ring.fillColor = CGColor(red: color.red, green: color.green, blue: color.blue, alpha: r.alpha * 0.18)
                ring.opacity = 1
            } else {
                ring.opacity = 0
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Live presenter

/// The live `CursorPresenting` over a `CursorPanel`, driving a lifelike motion model on a
/// main-thread display timer. AppKit windows must live on the main thread, but the action
/// path calls this from a background lane; so `show`/`update`/`hide` only record intent
/// under a lock and marshal a single "apply" block onto the main thread (coalesced). On the
/// main thread we feed the motion model and keep a ~60 fps timer running until the motion
/// settles, then park it.
///
/// Self-guards on `canPresent` so the controller never even reaches here without an active
/// windowing session.
public final class AppKitCursorPresenter: CursorPresenting {
    private struct Desired {
        var visible: Bool
        var color: CursorColor
        var panelFrame: Rect
        var cursorInPanel: Point
        var visualState: CursorVisualState
        /// Set by `update`; consumed by the apply block to feed the motion model exactly once.
        var pendingRetarget: Bool
        /// Set by `show` (overlay (re)acquired for a session): the next placement SNAPS instead
        /// of flying, so a fresh session's cursor appears in place rather than sliding in from
        /// the previous session's position.
        var needsSnap: Bool
    }

    private let lock = NSLock()
    private var desired = Desired(
        visible: false,
        color: CursorColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 0.95),
        panelFrame: Rect(x: 0, y: 0, width: 0, height: 0),
        cursorInPanel: Point(x: 0, y: 0),
        visualState: .idle,
        pendingRetarget: false,
        needsSnap: false
    )
    private var pending = false

    // Main-thread-only state.
    private var panel: CursorPanel?
    // Ripple sized to the normal-cursor arrow, not the model default.
    private let motion = CursorAnimator(config: CursorMotionConfig(rippleMaxRadius: 18))
    private var color = CursorColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 0.95)
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    public init() {}

    /// A windowing session exists iff there is an active main display. Delegates to the shared
    /// `GUISession.isAvailable` self-guard so the presenter guard and the `mcp` runtime's
    /// host/no-host decision can never diverge.
    public var canPresent: Bool { GUISession.isAvailable }

    public func show(color: CursorColor) {
        lock.lock()
        desired.visible = true
        desired.color = color
        desired.needsSnap = true
        lock.unlock()
        scheduleApply()
    }

    public func update(panelFrame: Rect, cursorInPanel: Point, visualState: CursorVisualState) {
        lock.lock()
        desired.visible = true
        desired.panelFrame = panelFrame
        desired.cursorInPanel = cursorInPanel
        desired.visualState = visualState
        desired.pendingRetarget = true
        lock.unlock()
        scheduleApply()
    }

    public func hide() {
        lock.lock()
        desired.visible = false
        lock.unlock()
        scheduleApply()
    }

    /// Enqueue exactly one "apply latest desired state" block on the main thread, unless one
    /// is already pending (coalescing). Runs inline when already on the main thread.
    private func scheduleApply() {
        lock.lock()
        if pending { lock.unlock(); return }
        pending = true
        lock.unlock()
        let apply: () -> Void = { [weak self] in self?.applyLatest() }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Apply the latest desired snapshot: position the panel, feed the motion model, and
    /// ensure the display timer is running (or torn down on hide). MAIN THREAD ONLY.
    private func applyLatest() {
        lock.lock()
        let snapshot = desired
        desired.pendingRetarget = false
        // Consume the snap flag ONLY when a position is applied this pass; a lone `show()`
        // (no position yet) leaves it set so the first real placement still snaps.
        if snapshot.pendingRetarget { desired.needsSnap = false }
        pending = false
        lock.unlock()

        guard snapshot.visible else {
            stopTimer()
            panel?.orderOut(nil)
            return
        }

        color = snapshot.color
        let panel = self.panel ?? CursorPanel()
        self.panel = panel
        panel.setFrame(Self.cocoaRect(fromGlobalTopLeft: snapshot.panelFrame), display: false)

        if snapshot.pendingRetarget {
            if snapshot.needsSnap {
                // Overlay (re)acquired for a session: snap in place rather than flying from a
                // stale position (fresh session, or first show).
                motion.reset(color: snapshot.color, at: snapshot.cursorInPanel)
            } else {
                motion.retarget(to: snapshot.cursorInPanel, state: snapshot.visualState)
            }
        }

        panel.orderFrontRegardless()   // show without activating
        startTimer()
    }

    // MARK: - Display timer

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        // ~60 fps on the hosted main run loop, in `.common` modes so it keeps firing during
        // event tracking. The overlay is decorative; this never touches the action path.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// One display step: advance the motion model by real elapsed time and render. Parks the
    /// timer once the motion has settled (tip at target, no live ripples, resting state).
    private func step() {
        let now = CACurrentMediaTime()
        let dt = max(0, now - lastTick)
        lastTick = now
        let frame = motion.tickRender(dt: dt)
        panel?.cursorView?.render(color: color, frame: frame)
        if frame.settled { stopTimer() }
    }

    // MARK: - Coordinate flip

    /// Convert a GLOBAL top-left-origin rect (protocol §9) to a Cocoa bottom-left-origin
    /// screen rect. The primary screen (index 0) defines the Cocoa origin; global CG y is
    /// measured from the top of that screen, so `cocoaY = primaryHeight − (y + height)`.
    static func cocoaRect(fromGlobalTopLeft rect: Rect) -> NSRect {
        let primaryHeight = NSScreen.screens.first.map { Double($0.frame.height) } ?? rect.height
        return cocoaRect(fromGlobalTopLeft: rect, primaryHeight: primaryHeight)
    }

    /// Pure coordinate flip (hermetically testable): given the primary screen's Cocoa
    /// height, map a GLOBAL top-left rect to a Cocoa bottom-left rect. `x`/`width`/`height`
    /// pass through; only `y` flips.
    static func cocoaRect(fromGlobalTopLeft rect: Rect, primaryHeight: Double) -> NSRect {
        NSRect(
            x: rect.x,
            y: primaryHeight - (rect.y + rect.height),
            width: rect.width,
            height: rect.height
        )
    }
}

public extension CursorController {
    /// A live, self-guarding controller for the running helper. Presents through
    /// `AppKitCursorPresenter` (which no-ops when there is no active display) with the
    /// `SEMANTOUCH_CURSOR` preference. Safe to construct in any context — it creates no window
    /// until an action actually reflects against a GUI session.
    static func system() -> CursorController {
        CursorController(
            presenter: AppKitCursorPresenter(),
            animator: CursorAnimator(),
            preference: .fromEnvironment()
        )
    }
}

#else

// Non-AppKit platforms (not a supported target, but keep the module buildable): the
// system controller is simply the inert one.
public extension CursorController {
    static func system() -> CursorController { .disabled() }
}

#endif
