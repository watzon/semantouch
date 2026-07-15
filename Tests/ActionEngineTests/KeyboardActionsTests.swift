import XCTest
import CoreGraphics
import ComputerUseCore
@testable import ActionEngine

/// Keymap + chord grammar goldens (§4.3, §16) and keyboard delivery over a recording
/// synthesizer. Permission-free: no real CGEvent is ever posted.
final class KeyboardActionsTests: XCTestCase {
    // MARK: - Keymap goldens

    func testModifierTokensMapToFlags() {
        XCTAssertEqual(Keymap.modifier(for: "cmd"), .maskCommand)
        XCTAssertEqual(Keymap.modifier(for: "ctrl"), .maskControl)
        XCTAssertEqual(Keymap.modifier(for: "opt"), .maskAlternate)
        XCTAssertEqual(Keymap.modifier(for: "shift"), .maskShift)
        XCTAssertEqual(Keymap.modifier(for: "fn"), .maskSecondaryFn)
        XCTAssertNil(Keymap.modifier(for: "a"))
        XCTAssertNil(Keymap.modifier(for: "hyper"))
    }

    func testKeyTokensMapToStableKeycodes() {
        // A representative slice of the ANSI table + named keys (golden keycodes).
        XCTAssertEqual(Keymap.keyCode(for: "a"), 0x00)
        XCTAssertEqual(Keymap.keyCode(for: "c"), 0x08)
        XCTAssertEqual(Keymap.keyCode(for: "v"), 0x09)
        XCTAssertEqual(Keymap.keyCode(for: "z"), 0x06)
        XCTAssertEqual(Keymap.keyCode(for: "4"), 0x15)
        XCTAssertEqual(Keymap.keyCode(for: "0"), 0x1D)
        XCTAssertEqual(Keymap.keyCode(for: "enter"), 0x24)
        XCTAssertEqual(Keymap.keyCode(for: "return"), 0x24)
        XCTAssertEqual(Keymap.keyCode(for: "tab"), 0x30)
        XCTAssertEqual(Keymap.keyCode(for: "space"), 0x31)
        XCTAssertEqual(Keymap.keyCode(for: "esc"), 0x35)
        XCTAssertEqual(Keymap.keyCode(for: "delete"), 0x33)
        XCTAssertEqual(Keymap.keyCode(for: "left"), 0x7B)
        XCTAssertEqual(Keymap.keyCode(for: "right"), 0x7C)
        XCTAssertEqual(Keymap.keyCode(for: "down"), 0x7D)
        XCTAssertEqual(Keymap.keyCode(for: "up"), 0x7E)
        XCTAssertEqual(Keymap.keyCode(for: "f1"), 0x7A)
        XCTAssertEqual(Keymap.keyCode(for: "f12"), 0x6F)
    }

    func testKeyLookupIsCaseInsensitive() {
        XCTAssertEqual(Keymap.keyCode(for: "A"), Keymap.keyCode(for: "a"))
        XCTAssertEqual(Keymap.keyCode(for: "ENTER"), 0x24)
        XCTAssertEqual(Keymap.modifier(for: "CMD"), .maskCommand)
    }

    // MARK: - Chord grammar

    func testSingleKeyChord() throws {
        let chords = try KeyChord.parse("a")
        XCTAssertEqual(chords, [KeyChord(flags: [], keyCode: 0x00)])
    }

    func testModifierPlusKey() throws {
        let chords = try KeyChord.parse("cmd+shift+4")
        XCTAssertEqual(chords.count, 1)
        XCTAssertEqual(chords[0].keyCode, 0x15)
        XCTAssertTrue(chords[0].flags.contains(.maskCommand))
        XCTAssertTrue(chords[0].flags.contains(.maskShift))
        XCTAssertFalse(chords[0].flags.contains(.maskControl))
    }

    func testMultiChordSequence() throws {
        // "cmd+a cmd+c" — select-all then copy.
        let chords = try KeyChord.parse("cmd+a cmd+c")
        XCTAssertEqual(chords, [
            KeyChord(flags: .maskCommand, keyCode: 0x00),
            KeyChord(flags: .maskCommand, keyCode: 0x08),
        ])
    }

    func testEmptyComboThrows() {
        XCTAssertThrowsError(try KeyChord.parse("")) { XCTAssertTrue($0 is KeyChordError) }
        XCTAssertThrowsError(try KeyChord.parse("   ")) { XCTAssertTrue($0 is KeyChordError) }
    }

    func testUnknownModifierThrows() {
        XCTAssertThrowsError(try KeyChord.parse("hyper+a")) { error in
            guard let e = error as? KeyChordError else { return XCTFail("expected KeyChordError") }
            XCTAssertTrue(e.message.contains("hyper"))
        }
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try KeyChord.parse("cmd+kittens")) { error in
            guard let e = error as? KeyChordError else { return XCTFail("expected KeyChordError") }
            XCTAssertTrue(e.message.contains("kittens"))
        }
    }

    func testEmptyChordTokenThrows() {
        // A trailing '+' leaves an empty key token.
        XCTAssertThrowsError(try KeyChord.parse("cmd+")) { XCTAssertTrue($0 is KeyChordError) }
        XCTAssertThrowsError(try KeyChord.parse("cmd++a")) { XCTAssertTrue($0 is KeyChordError) }
    }

    // MARK: - Delivery

    func testPressEmitsModifierWrappedChordSequence() {
        // FIX A (live macOS-26 finding): a `cmd+a` chord must post a REAL left-Command keyDown
        // (which produces the `flagsChanged` responders require) BEFORE the main key, carry
        // the mask on both, then release Command AFTER the main key — not merely set the flag
        // on a bare `a` event. Otherwise the responder never registers the Command chord and
        // `cmd+a` fails to select-all.
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        let chords = [
            KeyChord(flags: .maskCommand, keyCode: 0x00), // cmd+a
            KeyChord(flags: .maskCommand, keyCode: 0x08), // cmd+c
        ]
        let emitted = KeyboardActions.press(chords, via: synth, interruption: monitor)
        XCTAssertEqual(emitted, 2)
        XCTAssertEqual(synth.events, [
            // cmd+a: left-Command down (flagsChanged), a down, a up, left-Command up.
            .keyDown(0x37, .maskCommand),
            .keyDown(0x00, .maskCommand), .keyUp(0x00, .maskCommand),
            .keyUp(0x37, []),
            // cmd+c.
            .keyDown(0x37, .maskCommand),
            .keyDown(0x08, .maskCommand), .keyUp(0x08, .maskCommand),
            .keyUp(0x37, []),
        ])
    }

    func testPressMultiModifierChordPressesAndReleasesInStableNestedOrder() {
        // cmd+shift+4: modifiers pressed in stable order (shift then command), each event
        // carrying the modifiers held at that instant; the main key carries the full mask;
        // modifiers released in reverse (command then shift), clearing the mask as they go.
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let emitted = KeyboardActions.press([KeyChord(flags: flags, keyCode: 0x15)], via: synth, interruption: monitor)
        XCTAssertEqual(emitted, 1)
        XCTAssertEqual(synth.events, [
            .keyDown(0x38, [.maskShift]),                       // shift down
            .keyDown(0x37, [.maskShift, .maskCommand]),         // command down (both held)
            .keyDown(0x15, [.maskCommand, .maskShift]),         // 4 down (full mask)
            .keyUp(0x15, [.maskCommand, .maskShift]),           // 4 up
            .keyUp(0x37, [.maskShift]),                         // command up (shift still held)
            .keyUp(0x38, []),                                   // shift up (none held)
        ])
    }

    func testPressUnmodifiedChordEmitsBareKeyDownUp() {
        // No modifier ⇒ no wrapping modifier events; identical to a plain key press.
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        let emitted = KeyboardActions.press([KeyChord(flags: [], keyCode: 0x24)], via: synth, interruption: monitor)
        XCTAssertEqual(emitted, 1)
        XCTAssertEqual(synth.events, [.keyDown(0x24, []), .keyUp(0x24, [])])
    }

    func testPressStopsAtInterruption() {
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        // Flip interruption after the first chord's two events.
        var emitted = 0
        synth.onEmit = {
            emitted += 1
            if emitted == 2 { monitor.observe(isOurs: false, at: 1.0) }
        }
        let count = KeyboardActions.press([
            KeyChord(flags: [], keyCode: 0x00),
            KeyChord(flags: [], keyCode: 0x08),
            KeyChord(flags: [], keyCode: 0x09),
        ], via: synth, interruption: monitor)
        XCTAssertEqual(count, 1, "only the first chord runs before interruption cancels the rest")
        XCTAssertEqual(synth.events.count, 2)
    }

    func testTypeEmitsPerCharacter() {
        let synth = FakeSynthesizer()
        let monitor = InterruptionState()
        monitor.arm()
        let emitted = KeyboardActions.type("hé", via: synth, interruption: monitor)
        XCTAssertEqual(emitted, 2)
        XCTAssertEqual(synth.events, [.type("h"), .type("é")])
    }

    func testXdotoolModifierAliases() {
        XCTAssertEqual(Keymap.modifier(for: "super"), .maskCommand)
        XCTAssertEqual(Keymap.modifier(for: "meta"), .maskCommand)
        XCTAssertEqual(Keymap.modifier(for: "control"), .maskControl)
        XCTAssertEqual(Keymap.modifier(for: "alt"), .maskAlternate)
        XCTAssertEqual(Keymap.modifier(for: "SUPER"), .maskCommand)
        XCTAssertEqual(Keymap.modifier(for: "Control"), .maskControl)
        XCTAssertEqual(Keymap.modifier(for: "ALT"), .maskAlternate)
        // Old tokens still resolve.
        XCTAssertEqual(Keymap.modifier(for: "cmd"), .maskCommand)
        XCTAssertEqual(Keymap.modifier(for: "ctrl"), .maskControl)
        XCTAssertEqual(Keymap.modifier(for: "opt"), .maskAlternate)
    }

    func testXdotoolKeyAliases() {
        XCTAssertEqual(Keymap.keyCode(for: "Page_Up"), 0x74)
        XCTAssertEqual(Keymap.keyCode(for: "page_up"), 0x74)
        XCTAssertEqual(Keymap.keyCode(for: "PAGE_UP"), 0x74)
        XCTAssertEqual(Keymap.keyCode(for: "Page_Down"), 0x79)
        XCTAssertEqual(Keymap.keyCode(for: "Insert"), 0x72)
        XCTAssertEqual(Keymap.keyCode(for: "KP_0"), 0x52)
        XCTAssertEqual(Keymap.keyCode(for: "KP_9"), 0x5C)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Enter"), 0x4C)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Add"), 0x45)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Subtract"), 0x4E)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Multiply"), 0x43)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Divide"), 0x4B)
        XCTAssertEqual(Keymap.keyCode(for: "KP_Decimal"), 0x41)
        // Legacy tokens retained.
        XCTAssertEqual(Keymap.keyCode(for: "pageup"), 0x74)
        XCTAssertEqual(Keymap.keyCode(for: "delete"), 0x33)
        XCTAssertEqual(Keymap.keyCode(for: "Delete"), 0x33)
    }

    func testXdotoolAliasChordsParse() throws {
        let chords = try KeyChord.parse("super+c")
        XCTAssertEqual(chords.count, 1)
        XCTAssertEqual(chords[0].keyCode, 0x08)
        XCTAssertTrue(chords[0].flags.contains(.maskCommand))

        let page = try KeyChord.parse("Page_Up")
        XCTAssertEqual(page[0].keyCode, 0x74)

        let kp = try KeyChord.parse("KP_Enter")
        XCTAssertEqual(kp[0].keyCode, 0x4C)
    }

    func testUnknownTokensStillStrict() {
        XCTAssertThrowsError(try KeyChord.parse("hyper+a")) { error in
            guard let e = error as? KeyChordError else { return XCTFail("expected KeyChordError") }
            XCTAssertTrue(e.message.contains("hyper"))
        }
        XCTAssertThrowsError(try KeyChord.parse("cmd+kittens")) { error in
            guard let e = error as? KeyChordError else { return XCTFail("expected KeyChordError") }
            XCTAssertTrue(e.message.contains("kittens"))
        }
    }
}
