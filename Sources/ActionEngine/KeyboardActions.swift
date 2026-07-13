import Foundation
import CoreGraphics
import ComputerUseCore

// Keyboard fallback (docs/PROTOCOL.md §16): two pure, permission-free layers
// plus a thin delivery step:
//   - Keymap:        token → virtual keycode / modifier flag (golden-tested).
//   - KeyChord.parse: the §4.3 chord grammar → a list of chords (golden + error tests).
//   - KeyboardActions: emit the chords / literal text through an injected synthesizer,
//                      checking the interruption monitor between units.

// MARK: - Keymap

/// The frozen token → virtual-keycode / modifier-flag table for `press_key` chords
/// (§4.3, §16). Keycodes are the stable ANSI `kVK_*` values written as literals so the
/// engine does not depend on Carbon being importable; the wire token grammar is stable.
public enum Keymap {
    /// Named modifier tokens → CoreGraphics flags.
    public static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand,
        "ctrl": .maskControl,
        "opt": .maskAlternate,
        "shift": .maskShift,
        "fn": .maskSecondaryFn,
    ]

    /// Key token → ANSI virtual keycode. Lowercase named keys, digits, letters, and the
    /// common editing/navigation/function keys (§4.3).
    public static let keys: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]
        // Letters (kVK_ANSI_*).
        let letters: [(String, CGKeyCode)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05),
            ("z", 0x06), ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C),
            ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F),
            ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28),
            ("n", 0x2D), ("m", 0x2E),
        ]
        for (name, code) in letters { map[name] = code }
        // Digits (top row).
        let digits: [(String, CGKeyCode)] = [
            ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("5", 0x17), ("6", 0x16),
            ("7", 0x1A), ("8", 0x1C), ("9", 0x19), ("0", 0x1D),
        ]
        for (name, code) in digits { map[name] = code }
        // Punctuation.
        let punct: [(String, CGKeyCode)] = [
            ("=", 0x18), ("-", 0x1B), ("]", 0x1E), ("[", 0x21), ("'", 0x27), (";", 0x29),
            ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), (".", 0x2F), ("`", 0x32),
        ]
        for (name, code) in punct { map[name] = code }
        // Named keys.
        let named: [(String, CGKeyCode)] = [
            ("enter", 0x24), ("return", 0x24),
            ("tab", 0x30),
            ("space", 0x31),
            ("delete", 0x33), ("backspace", 0x33),
            ("forwarddelete", 0x75),
            ("esc", 0x35), ("escape", 0x35),
            ("home", 0x73), ("end", 0x77), ("pageup", 0x74), ("pagedown", 0x79),
            ("left", 0x7B), ("right", 0x7C), ("down", 0x7D), ("up", 0x7E),
            ("f1", 0x7A), ("f2", 0x78), ("f3", 0x63), ("f4", 0x76), ("f5", 0x60),
            ("f6", 0x61), ("f7", 0x62), ("f8", 0x64), ("f9", 0x65), ("f10", 0x6D),
            ("f11", 0x67), ("f12", 0x6F),
        ]
        for (name, code) in named { map[name] = code }
        return map
    }()

    /// The keycode for a key token, or `nil` when unknown.
    public static func keyCode(for token: String) -> CGKeyCode? { keys[token.lowercased()] }

    /// The modifier flag for a modifier token, or `nil` when it is not a modifier.
    public static func modifier(for token: String) -> CGEventFlags? { modifiers[token.lowercased()] }

    /// The virtual keycode that produces the `flagsChanged` event for each modifier flag,
    /// in a stable press order (release is the reverse). Left-hand ANSI `kVK_*` values.
    ///
    /// A chord's modifiers MUST be delivered as REAL modifier key-down events — not merely
    /// as a flag bit set on the main key event. Setting `.maskCommand` on a `cmd+a` key event
    /// tells the responder the Command bit is *held*, but many responders only recognize the
    /// chord (e.g. select-all) once the modifier's own `flagsChanged` event has arrived
    /// (live macOS-26 finding: flag-only `cmd+a` did not select-all). Posting a left-Command
    /// keyDown before the main key produces that `flagsChanged`; the matching keyUp afterward
    /// clears it. `fn` is last: it is a secondary-function flag, rarely part of a command
    /// chord, and least sensitive to ordering.
    public static let orderedModifierKeyCodes: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
        (.maskShift, 0x38),        // kVK_Shift (left)
        (.maskControl, 0x3B),      // kVK_Control (left)
        (.maskAlternate, 0x3A),    // kVK_Option (left)
        (.maskCommand, 0x37),      // kVK_Command (left)
        (.maskSecondaryFn, 0x3F),  // kVK_Function (fn)
    ]

    /// The (flag, keycode) modifier pairs present in `flags`, in stable press order.
    public static func modifierKeyCodes(in flags: CGEventFlags) -> [(flag: CGEventFlags, keyCode: CGKeyCode)] {
        orderedModifierKeyCodes.filter { flags.contains($0.flag) }
    }
}

// MARK: - Chord model + grammar

/// One resolved chord: a set of modifier flags plus one key. `press_key`'s `combo` is a
/// space-separated sequence of these (§4.3).
public struct KeyChord: Equatable, Sendable {
    public var flags: CGEventFlags
    public var keyCode: CGKeyCode

    public init(flags: CGEventFlags, keyCode: CGKeyCode) {
        self.flags = flags
        self.keyCode = keyCode
    }
}

/// A malformed `combo`. Surfaced by the handler as JSON-RPC `-32602` (Invalid params):
/// the chord grammar cannot be validated by the JSON Schema layer, so it is validated
/// here at decode time, before policy/session handling.
public struct KeyChordError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public extension KeyChord {
    /// Parse a `combo` string per §4.3: one or more chords separated by a single space;
    /// each chord is zero or more modifiers (`cmd|ctrl|opt|shift|fn`) then exactly one key
    /// token, joined by `+`. Throws `KeyChordError` on any malformed input.
    static func parse(_ combo: String) throws -> [KeyChord] {
        let trimmed = combo.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyChordError("empty combo") }
        // A single space separates chords; collapse runs so "a  b" is still two chords,
        // but reject empty chords from a leading/trailing separator (already trimmed).
        let chordTokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard !chordTokens.isEmpty else { throw KeyChordError("empty combo") }

        var chords: [KeyChord] = []
        for raw in chordTokens {
            chords.append(try parseChord(String(raw)))
        }
        return chords
    }

    private static func parseChord(_ chord: String) throws -> KeyChord {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 1, !parts.contains(where: { $0.isEmpty }) else {
            throw KeyChordError("malformed chord \"\(chord)\"")
        }
        // Everything but the last token is a modifier; the last is the key.
        let modifierTokens = parts.dropLast()
        let keyToken = parts[parts.count - 1]

        var flags: CGEventFlags = []
        for token in modifierTokens {
            guard let flag = Keymap.modifier(for: token) else {
                throw KeyChordError("unknown modifier \"\(token)\" in chord \"\(chord)\"")
            }
            flags.insert(flag)
        }
        guard let keyCode = Keymap.keyCode(for: keyToken) else {
            throw KeyChordError("unknown key \"\(keyToken)\" in chord \"\(chord)\"")
        }
        return KeyChord(flags: flags, keyCode: keyCode)
    }
}

// MARK: - Delivery

/// Emits parsed chords / literal text through the injected synthesizer. Each unit checks
/// the interruption monitor first, so genuine physical input cancels the remainder
/// promptly (docs/SECURITY.md §6).
public enum KeyboardActions {
    /// Deliver a chord sequence. Returns the number of chords actually emitted (fewer than
    /// the input when interrupted).
    @discardableResult
    public static func press(
        _ chords: [KeyChord],
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) -> Int {
        var emitted = 0
        for chord in chords {
            if interruption.isInterrupted { break }
            // Stop before delivering if the target is no longer frontmost, so a key never lands
            // in an app that stole the foreground mid-sequence (§16.3 step 5). The check is at
            // chord granularity: a chord is emitted atomically so a modifier is never left held
            // down (which would corrupt the user's next physical keystroke).
            if !onTarget.stillOnTarget() { break }
            emit(chord, via: synthesizer)
            emitted += 1
        }
        return emitted
    }

    /// Emit one chord as a real modifier-wrapped key sequence (§16.6): press each modifier
    /// key (accumulating the mask so every event carries the modifiers held *at that instant*),
    /// press+release the main key with the full modifier mask, then release each modifier in
    /// reverse (clearing the mask as it goes). For an unmodified chord this is exactly the main
    /// key's down/up, unchanged from before. Emitted whole so no modifier is ever left stuck.
    ///
    /// This loop unconditionally releases every modifier it pressed; the matching release
    /// therefore cannot be skipped by control flow here. The remaining risk — a modifier keyUp
    /// dropped at the synthesizer if its `CGEvent` failed to construct — is closed in
    /// `CGEventSynthesizer.postKey`, which falls back to a source-less construction so a modifier
    /// release is always posted (a stranded, stuck modifier would otherwise corrupt the user's
    /// subsequent input).
    static func emit(_ chord: KeyChord, via synthesizer: InputSynthesizer) {
        let mods = Keymap.modifierKeyCodes(in: chord.flags)
        var held: CGEventFlags = []
        for mod in mods {
            held.insert(mod.flag)
            synthesizer.keyDown(keyCode: mod.keyCode, flags: held)
        }
        // The main key carries the complete modifier mask (== `held` after all mods pressed).
        synthesizer.keyDown(keyCode: chord.keyCode, flags: chord.flags)
        synthesizer.keyUp(keyCode: chord.keyCode, flags: chord.flags)
        for mod in mods.reversed() {
            held.remove(mod.flag)
            synthesizer.keyUp(keyCode: mod.keyCode, flags: held)
        }
    }

    /// Deliver literal text one character at a time (so interruption is fine-grained).
    /// Returns the number of characters emitted.
    @discardableResult
    public static func type(
        _ text: String,
        via synthesizer: InputSynthesizer,
        interruption: InterruptionMonitoring,
        onTarget: TargetGuard = .alwaysOn
    ) -> Int {
        var emitted = 0
        for character in text {
            if interruption.isInterrupted { break }
            if !onTarget.stillOnTarget() { break }
            synthesizer.typeUnicode(String(character))
            emitted += 1
        }
        return emitted
    }
}
