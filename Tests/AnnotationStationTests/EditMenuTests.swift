import XCTest
import AppKit
@testable import AnnotationStation

/// The Edit menu is invisible, so nothing on screen would show if it went missing — but ⌘V
/// would stop working in every note field, and dictation with it.
final class EditMenuTests: XCTestCase {
    private func editMenu() throws -> NSMenu {
        let items = EditMenu.make().items.compactMap(\.submenu)
        return try XCTUnwrap(items.first { $0.title == "Edit" })
    }

    func testCarriesTheStandardEditingCommands() throws {
        let edit = try editMenu()
        let bindings = Dictionary(uniqueKeysWithValues: edit.items
            .filter { !$0.isSeparatorItem }
            .map { ($0.keyEquivalent, $0.action) })
        XCTAssertEqual(bindings["x"], #selector(NSText.cut(_:)))
        XCTAssertEqual(bindings["c"], #selector(NSText.copy(_:)))
        XCTAssertEqual(bindings["v"], #selector(NSText.paste(_:)))
        XCTAssertEqual(bindings["a"], #selector(NSText.selectAll(_:)))
    }

    /// A target would pin each command to one object; nil sends it to whatever has focus.
    func testCommandsGoToTheResponderChain() throws {
        for item in try editMenu().items where !item.isSeparatorItem {
            XCTAssertNil(item.target, "\(item.title) should dispatch down the responder chain")
        }
    }

    /// ⌘Z already undoes the last mark, in the overlay's keyDown. A menu item would take the
    /// keystroke first and that undo would stop working.
    func testDoesNotClaimCommandZ() throws {
        XCTAssertFalse(try editMenu().items.contains { $0.keyEquivalent == "z" })
    }

    /// ⌘Q here would be live while the overlay is up and would discard an open session.
    func testNoGlobalQuitBinding() {
        let all = EditMenu.make().items.compactMap(\.submenu).flatMap(\.items)
        XCTAssertFalse(all.contains { $0.keyEquivalent == "q" })
    }
}
