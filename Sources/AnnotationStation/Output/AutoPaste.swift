import AppKit
import Carbon

/// Bring the agent app to the front and post ⌘V (PLAN.md §2, M3).
/// Only the two known targets get a paste; everything else is clipboard-only (§8).
///
/// Target choice deviates from the plan on purpose: the app that was frontmost before the
/// overlay is the thing being annotated (a browser, Figma…), not the agent. So the target is
/// the most recently used *running* known target, wherever it is (other window, other display).
enum AutoPaste {
    /// Priority order when none of them has been used recently.
    static let knownTargetsByPriority: [String] = [
        "com.anthropic.claudefordesktop",   // Claude Desktop (Code tab)
        "com.mitchellh.ghostty",            // Ghostty
    ]
    static let knownTargets: Set<String> = Set(knownTargetsByPriority)

    enum Outcome {
        case pasted(String)
        case copiedOnly(reason: String)
    }

    static func isKnownTarget(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return knownTargets.contains(id)
    }

    /// Activates `app`, waits for it to become active (≤ 1 s), then posts ⌘V.
    /// Needs Accessibility; if missing, shows the system prompt once and reports `copiedOnly`.
    static func paste(into app: NSRunningApplication, completion: @escaping (Outcome) -> Void) {
        guard Permissions.hasAccessibility() else {
            Permissions.requestAccessibility()
            completion(.copiedOnly(reason: "Accessibility not granted"))
            return
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "target"
        app.activate(from: .current, options: [])
        waitUntilActive(app, attemptsLeft: 20) { active in
            guard active else {
                completion(.copiedOnly(reason: "\(name) did not become active"))
                return
            }
            // Small settle so the target's key window is ready for input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if postCommandV() {
                    completion(.pasted(name))
                } else {
                    completion(.copiedOnly(reason: "could not synthesize ⌘V"))
                }
            }
        }
    }

    private static func waitUntilActive(_ app: NSRunningApplication, attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
        if app.isActive { completion(true); return }
        guard attemptsLeft > 0 else { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilActive(app, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    private static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Remembers which known target the user touched last so Send goes there.
final class PasteTargetTracker {
    private var lastUsed: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, AutoPaste.isKnownTarget(front) {
            lastUsed = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  AutoPaste.isKnownTarget(app) else { return }
            self?.lastUsed = app
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The most recently used running target, else any running target by priority, else nil.
    func currentTarget() -> NSRunningApplication? {
        if let app = lastUsed, !app.isTerminated { return app }
        lastUsed = nil
        let running = NSWorkspace.shared.runningApplications
        for id in AutoPaste.knownTargetsByPriority {
            if let app = running.first(where: { $0.bundleIdentifier == id && !$0.isTerminated }) { return app }
        }
        return nil
    }
}
