import AppKit

/// The invisible Edit menu that makes ⌘X / ⌘C / ⌘V / ⌘A work in our own text fields.
///
/// macOS dispatches the standard editing commands through `NSApp.mainMenu`'s key equivalents,
/// *before* a keystroke ever reaches `keyDown`. An app that never sets a main menu therefore
/// drops them silently — which is what happened here: typing in a note or the compose panel
/// worked, but nothing could be pasted into it.
///
/// This also fixes dictation. VoiceInk, and most dictation tools, insert a transcript by putting
/// it on the pasteboard and synthesising ⌘V; a synthetic ⌘V travels the same path as a real one,
/// so it was being dropped for the same reason.
///
/// An `LSUIElement` app never displays a menu bar, so none of this is visible. It exists only to
/// be found by key-equivalent lookup.
enum EditMenu {
    static func install(into app: NSApplication = .shared) {
        app.mainMenu = make()
    }

    /// Built separately from installing it so the structure can be asserted in tests.
    static func make() -> NSMenu {
        let main = NSMenu()

        // Convention puts the app menu first. Ours is deliberately empty: a Quit item here would
        // give ⌘Q a global binding while the overlay is up, which would throw away an open
        // session mid-annotation. Quit stays in the status-bar menu, where it has to be chosen.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        // nil targets: each command is dispatched down the responder chain to whatever has focus,
        // which is the field editor whenever a note or the compose panel is up.
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Undo and Redo are left out on purpose. ⌘Z already means "undo the last mark", handled
        // in the overlay's keyDown; an Undo item here would intercept it before it got there.

        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}
