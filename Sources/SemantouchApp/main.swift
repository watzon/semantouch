import AppKit
import Foundation

// SemantouchHost — resident signed app process.
//
// Owns the private host socket, ComputerUseService, TCC grants, and the
// onboarding/status UI (via AppDelegate). The nested `semantouch` CLI is a
// stdio/control relay only and never imports the engines.
//
// Product/executable name is `SemantouchHost` so it cannot collide with the
// nested lowercase `semantouch` relay on case-insensitive APFS volumes.
//
// AppDelegate is @MainActor. Executable top-level entry runs on the main thread;
// `MainActor.assumeIsolated` bridges construction without `@main` (which cannot
// coexist with SPM `main.swift` top-level code).

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Activation policy is set again in applicationDidFinishLaunching; set it here
    // so the process is accessory before any windows exist.
    app.setActivationPolicy(.accessory)
    app.run()
}
