import XCTest
import Carbon
@testable import AnnotationStation

/// The hotkey is typed by hand into defaults, so parsing is where this feature breaks.
final class VoiceControlTests: XCTestCase {
    func testParsesModifiersAndKey() throws {
        let key = try XCTUnwrap(VoiceControl.HotKey("ctrl+opt+d"))
        XCTAssertEqual(key.keyCode, CGKeyCode(kVK_ANSI_D))
        XCTAssertEqual(key.flags, [.maskControl, .maskAlternate])
    }

    func testIgnoresCaseAndSpacing() {
        XCTAssertEqual(VoiceControl.HotKey("ctrl+opt+d"), VoiceControl.HotKey(" CTRL + Opt + D "))
    }

    func testAcceptsNamedKeys() throws {
        XCTAssertEqual(try XCTUnwrap(VoiceControl.HotKey("cmd+shift+space")).keyCode, CGKeyCode(kVK_Space))
        XCTAssertEqual(try XCTUnwrap(VoiceControl.HotKey("f5")).keyCode, CGKeyCode(kVK_F5))
    }

    func testBareKeyNeedsNoModifier() throws {
        let key = try XCTUnwrap(VoiceControl.HotKey("f13"))
        XCTAssertEqual(key.flags, [])
    }

    /// Anything unparseable has to read as "off" rather than as some other key, which would
    /// press whatever that key happens to do in whatever app is in front.
    func testUnparseableIsOff() {
        XCTAssertNil(VoiceControl.HotKey(nil))
        XCTAssertNil(VoiceControl.HotKey(""))
        XCTAssertNil(VoiceControl.HotKey("   "))
        XCTAssertNil(VoiceControl.HotKey("ctrl+opt"))        // modifiers only
        XCTAssertNil(VoiceControl.HotKey("ctrl+banana"))     // unknown key name
        XCTAssertNil(VoiceControl.HotKey("ctrl+a+b"))        // two keys is a typo, not a chord
    }
}
