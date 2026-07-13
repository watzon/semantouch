import AppKit
import Foundation

/// The fixture's application delegate. Builds a deterministic AppKit UI entirely in
/// code (no xib), assigns a stable `AXIdentifier` to every control the engine tests
/// target, and appends a JSON line to the state file for every state-changing event.
///
/// Focus discipline: unless `--activate` is passed the app never calls
/// `NSApp.activate(...)` and orders windows in with `orderFrontRegardless()`, so
/// covered-window and noninterference tests stay honest (the fixture does not steal
/// the user's foreground app).
final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate,
                         NSTableViewDataSource, NSTableViewDelegate {

    private let config: Config
    private let log: EventLog

    // Main window + tracked mutable state.
    private var window: NSWindow!
    private var pressCount: Int = 0
    private var countLabel: NSTextField!
    private var textField: NSTextField!
    private var mirrorLabel: NSTextField!
    private var tableView: NSTableView!
    private var rows: [String] = (1...50).map { "Row \($0)" }

    // Auxiliary windows.
    private var coverWindow: NSWindow?
    private var secondWindow: NSWindow?
    private var sheetWindow: NSWindow?

    private let rowColumnID = NSUserInterfaceItemIdentifier("fixture.table.column")

    init(config: Config) {
        self.config = config
        self.log = EventLog(path: config.stateFile)
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildMainWindow()
        if let coverFrame = config.cover {
            buildCoverWindow(frame: coverFrame)
        }
        if config.secondWindow {
            buildSecondWindow()
        }

        if config.activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Show without stealing foreground focus.
            window.orderFrontRegardless()
        }

        log.log("ready", control: "fixture.app", value: .string(config.title))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // Application menu (holds Quit so the app is quittable).
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // "Fixture" menu with the scripted items.
        let fixtureItem = NSMenuItem()
        mainMenu.addItem(fixtureItem)
        let fixtureMenu = NSMenu(title: "Fixture")
        fixtureItem.submenu = fixtureMenu

        // Menu items carry the documented AXIdentifiers (docs/FIXTURE.md). AppKit maps
        // an NSMenuItem's `setAccessibilityIdentifier` onto its AX element, so a menu
        // walk sees `fixture.menu.ping` / `fixture.menu.showSheet` (the window-rooted
        // MCP tree still does not include the menu bar; the identifiers matter to a
        // menu-bar walk / AppKit AX inspection).
        let ping = NSMenuItem(title: "Ping", action: #selector(onPing(_:)), keyEquivalent: "")
        ping.target = self
        ping.setAccessibilityIdentifier("fixture.menu.ping")
        fixtureMenu.addItem(ping)

        let showSheet = NSMenuItem(title: "Show Sheet", action: #selector(onShowSheet(_:)), keyEquivalent: "")
        showSheet.target = self
        showSheet.setAccessibilityIdentifier("fixture.menu.showSheet")
        fixtureMenu.addItem(showSheet)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Main window

    private func buildMainWindow() {
        window = NSWindow(
            contentRect: config.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.title
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.setFrame(config.frame, display: false)

        let content = NSView()
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // 1) Press button + count label.
        let pressButton = makeButton(title: "Press Me", id: "fixture.button.press", action: #selector(onPress(_:)))
        countLabel = makeLabel(text: "Presses: 0", id: "fixture.label.count")
        stack.addArrangedSubview(makeRow([pressButton, countLabel]))

        // 2) Editable text field + read-only mirror label.
        textField = NSTextField()
        textField.placeholderString = "Type here"
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        textField.setAccessibilityIdentifier("fixture.field.text")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        mirrorLabel = makeLabel(text: "", id: "fixture.label.mirror")
        stack.addArrangedSubview(makeRow([textField, mirrorLabel]))

        // 3) Static label.
        let staticLabel = makeLabel(text: "Static label", id: "fixture.label.static")
        stack.addArrangedSubview(staticLabel)

        // 4) Add Row / Remove Row.
        let addRow = makeButton(title: "Add Row", id: "fixture.button.addRow", action: #selector(onAddRow(_:)))
        let removeRow = makeButton(title: "Remove Row", id: "fixture.button.removeRow", action: #selector(onRemoveRow(_:)))
        stack.addArrangedSubview(makeRow([addRow, removeRow]))

        // 5) Two buttons both titled "Duplicate" with distinct identifiers.
        let dup1 = makeButton(title: "Duplicate", id: "fixture.button.dup1", action: #selector(onDup1(_:)))
        let dup2 = makeButton(title: "Duplicate", id: "fixture.button.dup2", action: #selector(onDup2(_:)))
        stack.addArrangedSubview(makeRow([dup1, dup2]))

        // 6) Popup + checkbox + permanently disabled button.
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Option 1", "Option 2", "Option 3"])
        popup.target = self
        popup.action = #selector(onPopup(_:))
        popup.setAccessibilityIdentifier("fixture.popup")

        let checkbox = NSButton(checkboxWithTitle: "Checkbox", target: self, action: #selector(onCheckbox(_:)))
        checkbox.setAccessibilityIdentifier("fixture.checkbox")

        let disabled = makeButton(title: "Disabled", id: "fixture.button.disabled", action: #selector(onDisabled(_:)))
        disabled.isEnabled = false

        stack.addArrangedSubview(makeRow([popup, checkbox, disabled]))

        // 7) Scroll view with 50 rows.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        tableView = NSTableView()
        let column = NSTableColumn(identifier: rowColumnID)
        column.title = "Rows"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("fixture.table")
        scrollView.documentView = tableView

        stack.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    // MARK: - Cover window

    private func buildCoverWindow(frame: NSRect) {
        let cover = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        cover.isOpaque = true
        cover.hasShadow = false
        cover.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.0, alpha: 1.0)
        cover.level = .floating
        cover.isReleasedWhenClosed = false
        cover.ignoresMouseEvents = false
        cover.setFrame(frame, display: false)
        cover.orderFrontRegardless()
        coverWindow = cover
    }

    // MARK: - Second window

    private func buildSecondWindow() {
        let frame = NSRect(
            x: config.frame.origin.x + 60,
            y: config.frame.origin.y - 60,
            width: 360,
            height: 240
        )
        let second = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        second.title = "CU Fixture B"
        second.level = .normal
        second.isReleasedWhenClosed = false

        let content = NSView()
        second.contentView = content
        let label = makeLabel(text: "Second window (CU Fixture B)", id: "fixture.second.label")
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        second.setFrame(frame, display: false)
        second.orderFrontRegardless()
        secondWindow = second
    }

    // MARK: - Actions

    @objc private func onPress(_ sender: Any?) {
        incrementPresses(source: "fixture.button.press")
    }

    @objc private func onPing(_ sender: Any?) {
        incrementPresses(source: "fixture.menu.ping")
    }

    private func incrementPresses(source: String) {
        pressCount += 1
        countLabel.stringValue = "Presses: \(pressCount)"
        log.log("press", control: source, value: .int(pressCount))
    }

    @objc private func onAddRow(_ sender: Any?) {
        rows.append("Row \(rows.count + 1)")
        tableView.reloadData()
        if rows.count > 0 {
            tableView.scrollRowToVisible(rows.count - 1)
        }
        log.log("addRow", control: "fixture.button.addRow", value: .int(rows.count))
    }

    @objc private func onRemoveRow(_ sender: Any?) {
        guard !rows.isEmpty else {
            log.log("removeRow", control: "fixture.button.removeRow", value: .int(0))
            return
        }
        rows.removeLast()
        tableView.reloadData()
        log.log("removeRow", control: "fixture.button.removeRow", value: .int(rows.count))
    }

    @objc private func onDup1(_ sender: Any?) {
        log.log("press", control: "fixture.button.dup1")
    }

    @objc private func onDup2(_ sender: Any?) {
        log.log("press", control: "fixture.button.dup2")
    }

    @objc private func onPopup(_ sender: Any?) {
        let title = (sender as? NSPopUpButton)?.titleOfSelectedItem ?? ""
        log.log("select", control: "fixture.popup", value: .string(title))
    }

    @objc private func onCheckbox(_ sender: Any?) {
        let on = (sender as? NSButton)?.state == .on
        log.log("toggle", control: "fixture.checkbox", value: .bool(on))
    }

    @objc private func onDisabled(_ sender: Any?) {
        // Never fires (button is permanently disabled); logged defensively.
        log.log("press", control: "fixture.button.disabled")
    }

    @objc private func onShowSheet(_ sender: Any?) {
        guard sheetWindow == nil else { return }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Sheet"

        let content = NSView()
        sheet.contentView = content

        let label = makeLabel(text: "Fixture sheet", id: "fixture.sheet.label")
        let ok = makeButton(title: "OK", id: "fixture.sheet.ok", action: #selector(onSheetOK(_:)))
        ok.keyEquivalent = "\r"

        let sheetStack = NSStackView(views: [label, ok])
        sheetStack.orientation = .vertical
        sheetStack.alignment = .centerX
        sheetStack.spacing = 16
        sheetStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sheetStack)
        NSLayoutConstraint.activate([
            sheetStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            sheetStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        sheetWindow = sheet
        log.log("showSheet", control: "fixture.menu.showSheet")
        window.beginSheet(sheet) { [weak self] _ in
            self?.sheetWindow = nil
        }
    }

    @objc private func onSheetOK(_ sender: Any?) {
        log.log("sheetOK", control: "fixture.sheet.ok")
        if let sheet = sheetWindow {
            window.endSheet(sheet)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === textField else { return }
        let value = field.stringValue
        mirrorLabel.stringValue = value
        log.log("textChanged", control: "fixture.field.text", value: .string(value))
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let reuseID = NSUserInterfaceItemIdentifier("fixture.table.cell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: reuseID, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = reuseID
            cell.isBordered = false
            cell.drawsBackground = false
            cell.isEditable = false
        }
        cell.stringValue = row < rows.count ? rows[row] : ""
        return cell
    }

    // MARK: - Control builders

    private func makeButton(title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func makeLabel(text: String, id: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.setAccessibilityIdentifier(id)
        return label
    }

    private func makeRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }
}
