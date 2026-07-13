import AppKit
import Foundation

// computer-use-fixture — deterministic AppKit test harness (docs/FIXTURE.md).
// A programmatic (no-xib) app that exposes a controlled, scriptable
// UI surface for the engine tests: press counter, settable text field with a read-only
// mirror, a static label, a 50-row scrollable table with add/remove mutation, duplicate
// titled buttons (distinct AXIdentifiers), a popup, a checkbox, a permanently disabled
// button, a "Fixture" menu (Ping / Show Sheet), plus optional cover-window and
// second-window modes and a JSON event log for observing state changes without pixels.
//
// The fixture never writes to stdout; diagnostics go to stderr and state changes go to
// the --state-file. Activation policy is .regular (it needs real windows and a menu
// bar). It does NOT steal focus unless --activate is passed, so covered-window and
// noninterference tests stay honest.

let config = Config.parse(CommandLine.arguments)

let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
