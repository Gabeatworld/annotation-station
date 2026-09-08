import AppKit

/// Menu-bar icon, the `screens · marks` badge, and the menu:
/// Capture, Send…, Discard Session, Recent Sessions ▸, Quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    var onCapture: (() -> Void)?
    var onSend: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRecentSelected: ((URL) -> Void)?
    var onSessions: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Supplies finished sessions (newest first) when the Recent submenu opens.
    var recentSessionsProvider: (() -> [URL])?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "No open session", action: nil, keyEquivalent: "")
    private let sendItem: NSMenuItem
    private let discardItem: NSMenuItem
    private let recentMenu = NSMenu(title: "Recent Sessions")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        sendItem = NSMenuItem(title: "Send Session…", action: #selector(send(_:)), keyEquivalent: "\r")
        discardItem = NSMenuItem(title: "Discard Session", action: #selector(discard(_:)), keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.dashed.badge.record", accessibilityDescription: "Annotation Station")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Annotation Station — ⌘⇧A capture · ⌘⇧⏎ send"
        }

        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        // Key equivalents here are display-only; the real shortcuts are Carbon hotkeys.
        let captureItem = NSMenuItem(title: "Capture Screen", action: #selector(capture(_:)), keyEquivalent: "A")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        sendItem.keyEquivalentModifierMask = [.command, .shift]
        sendItem.target = self
        menu.addItem(sendItem)

        discardItem.target = self
        menu.addItem(discardItem)

        menu.addItem(.separator())
        let sessionsItem = NSMenuItem(title: "Sessions…", action: #selector(sessions(_:)), keyEquivalent: "")
        sessionsItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        sessionsItem.target = self
        menu.addItem(sessionsItem)
        let recentItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Annotation Station", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.autoenablesItems = false
        statusItem.menu = menu
        update(sessionOpen: false, badge: "")
    }

    func update(sessionOpen: Bool, badge: String) {
        statusItem.button?.title = badge.isEmpty ? "" : " \(badge)"
        stateItem.title = sessionOpen ? "Open session: \(badge) (screens · marks)" : "No open session"
        sendItem.isEnabled = sessionOpen
        discardItem.isEnabled = sessionOpen
    }

    // MARK: NSMenuDelegate (Recent Sessions)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let sessions = recentSessionsProvider?() ?? []
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No finished sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in sessions {
            let item = NSMenuItem(title: "\(url.lastPathComponent)  — copy prompt", action: #selector(recent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func capture(_ sender: Any?) { onCapture?() }
    @objc private func send(_ sender: Any?) { onSend?() }
    @objc private func discard(_ sender: Any?) { onDiscard?() }
    @objc private func sessions(_ sender: Any?) { onSessions?() }
    @objc private func quit(_ sender: Any?) { onQuit?() }
    @objc private func recent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { onRecentSelected?(url) }
    }
}
