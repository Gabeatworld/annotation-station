import AppKit
import Carbon

/// Presses a dictation app's global record hotkey, so a note can start listening the moment it
/// opens and stop the moment you are done.
///
/// VoiceInk — the dictation app this was built for — exposes no URL scheme, no AppleScript
/// dictionary and no CLI. Its global hotkey is the only way in. That is fine: the app already
/// synthesises ⌘V for auto-paste and already holds the Accessibility permission that needs, so
/// pressing some other combination is the same mechanism pointed somewhere else.
///
/// Off unless a hotkey is configured, because there is nothing sensible to guess:
///
///     defaults write com.gabe.annotation-station voiceHotKey "ctrl+opt+d"
///
/// Set it to whatever VoiceInk ▸ Settings has for toggling the recorder.
enum VoiceControl {
    static let defaultsKey = "voiceHotKey"

    /// A parsed hotkey, or nil when unset or unparseable — either way the feature stays off.
    static var hotKey: HotKey? {
        HotKey(UserDefaults.standard.string(forKey: defaultsKey))
    }

    static var isEnabled: Bool { hotKey != nil }

    struct HotKey: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags

        /// Parses "ctrl+opt+d", "cmd+shift+space", "f5". Case and spacing are not significant.
        init?(_ string: String?) {
            guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var flags: CGEventFlags = []
            var key: CGKeyCode?
            for raw in string.lowercased().split(separator: "+") {
                let part = raw.trimmingCharacters(in: .whitespaces)
                switch part {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
                case "shift", "⇧": flags.insert(.maskShift)
                default:
                    // Two keys named in one string is a typo, not a chord we can send.
                    guard key == nil, let code = Self.keyCode(for: part) else { return nil }
                    key = code
                }
            }
            guard let key else { return nil }
            self.keyCode = key
            self.flags = flags
        }

        private static func keyCode(for name: String) -> CGKeyCode? {
            if name.count == 1, let scalar = name.unicodeScalars.first, let code = letters[scalar] {
                return code
            }
            return named[name]
        }

        private static let letters: [Unicode.Scalar: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
        ]

        private static let named: [String: CGKeyCode] = [
            "space": CGKeyCode(kVK_Space), "return": CGKeyCode(kVK_Return),
            "enter": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
            "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
            "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
            "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
            "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
            "f13": CGKeyCode(kVK_F13), "f14": CGKeyCode(kVK_F14), "f15": CGKeyCode(kVK_F15),
        ]
    }

    /// Presses the hotkey. The same press starts and stops in VoiceInk, so callers track which
    /// of the two they meant.
    @discardableResult
    static func toggleRecording() -> Bool {
        guard let hotKey else { return false }
        guard Permissions.hasAccessibility() else {
            Log.info("voice: Accessibility not granted, cannot press the record hotkey")
            return false
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: false)
        else {
            Log.error("voice: could not synthesize the record hotkey")
            return false
        }
        down.flags = hotKey.flags
        up.flags = hotKey.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
