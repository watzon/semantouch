import AppKit
import Foundation
import ComputerUseCore

/// Compact AppKit onboarding/status window for Accessibility + Screen Recording,
/// signing/version, active sessions, and update status.
///
/// Constructed lazily by `AppDelegate` only when UI is needed. The window is
/// key-capable when shown; the app still never activates merely because MCP
/// connected — activation is explicit when this controller presents.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var model: PermissionPresentationModel

    private let readinessLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityWhyLabel = NSTextField(wrappingLabelWithString: "")
    private let screenRecordingStatusLabel = NSTextField(labelWithString: "")
    private let screenRecordingWhyLabel = NSTextField(wrappingLabelWithString: "")
    private let identityLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionsLabel = NSTextField(labelWithString: "")
    private let remediationLabel = NSTextField(wrappingLabelWithString: "")
    private let updateLabel = NSTextField(wrappingLabelWithString: "")

    var onRecheck: (() -> Void)?
    var onRequestPermissions: (() -> Void)?
    var onOpenPrivacySettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onReopen: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: PermissionPresentationModel = PermissionPresentationModel()) {
        self.model = model

        let contentRect = NSRect(x: 0, y: 0, width: 460, height: 520)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Semantouch"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()

        super.init()
        window.delegate = self
        window.contentView = buildContentView()
        apply(model)
    }

    var isVisible: Bool {
        window.isVisible
    }

    func apply(_ model: PermissionPresentationModel) {
        self.model = model
        readinessLabel.stringValue = model.readinessSummary
        accessibilityStatusLabel.stringValue = "Accessibility: \(model.accessibilityStatusLabel)"
        accessibilityWhyLabel.stringValue = model.accessibilityWhyNeeded
        screenRecordingStatusLabel.stringValue = "Screen Recording: \(model.screenRecordingStatusLabel)"
        screenRecordingWhyLabel.stringValue = model.screenRecordingWhyNeeded
        identityLabel.stringValue = model.appIdentityLabel
        sessionsLabel.stringValue = model.activeSessionsLabel
        remediationLabel.stringValue = model.remediationSummary.isEmpty
            ? "No remediation needed."
            : model.remediationSummary
        updateLabel.stringValue = model.updateStatusLabel
    }

    /// Show the window and make it key. Callers may activate the app when the
    /// user explicitly launched onboarding or a required grant is missing.
    func showWindow(activate: Bool) {
        window.makeKeyAndOrderFront(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: - Layout

    private func buildContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))

        let title = makeHeading("Semantouch Status")
        configureLabel(readinessLabel, font: .systemFont(ofSize: 13, weight: .semibold))
        configureLabel(accessibilityStatusLabel)
        configureLabel(accessibilityWhyLabel, secondary: true)
        configureLabel(screenRecordingStatusLabel)
        configureLabel(screenRecordingWhyLabel, secondary: true)
        configureLabel(identityLabel, secondary: true)
        configureLabel(sessionsLabel)
        configureLabel(remediationLabel, secondary: true)
        configureLabel(updateLabel, secondary: true)

        let recheckButton = makeButton("Recheck", action: #selector(recheckTapped(_:)))
        let requestButton = makeButton("Request Permissions", action: #selector(requestPermissionsTapped(_:)))
        let privacyButton = makeButton("Open Privacy Settings", action: #selector(openPrivacySettingsTapped(_:)))
        let updateButton = makeButton("Check for Updates", action: #selector(checkForUpdatesTapped(_:)))
        let reopenButton = makeButton("Reopen", action: #selector(reopenTapped(_:)))
        let quitButton = makeButton("Quit", action: #selector(quitTapped(_:)))

        let stack = NSStackView(views: [
            title,
            readinessLabel,
            separator(),
            accessibilityStatusLabel,
            accessibilityWhyLabel,
            screenRecordingStatusLabel,
            screenRecordingWhyLabel,
            separator(),
            identityLabel,
            sessionsLabel,
            remediationLabel,
            updateLabel,
            separator(),
            buttonRow([recheckButton, requestButton]),
            buttonRow([privacyButton, updateButton]),
            buttonRow([reopenButton, quitButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        return root
    }

    private func makeHeading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 16, weight: .bold)
        field.alignment = .left
        return field
    }

    private func configureLabel(_ field: NSTextField, font: NSFont? = nil, secondary: Bool = false) {
        field.font = font ?? .systemFont(ofSize: 12)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - Actions

    @objc private func recheckTapped(_ sender: Any?) {
        onRecheck?()
    }

    @objc private func requestPermissionsTapped(_ sender: Any?) {
        onRequestPermissions?()
    }

    @objc private func openPrivacySettingsTapped(_ sender: Any?) {
        onOpenPrivacySettings?()
    }

    @objc private func checkForUpdatesTapped(_ sender: Any?) {
        onCheckForUpdates?()
    }

    @objc private func reopenTapped(_ sender: Any?) {
        onReopen?()
    }

    @objc private func quitTapped(_ sender: Any?) {
        onQuit?()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window hides it; the accessory host keeps running.
        window.orderOut(nil)
        return false
    }
}
