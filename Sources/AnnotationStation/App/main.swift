import AppKit

// Entry point. The app is an LSUIElement (menu-bar only) app: no Dock icon, no main window.
// Everything is wired up in AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
