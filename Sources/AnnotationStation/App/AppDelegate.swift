import AppKit
import Carbon

/// Wires everything and owns the state machine from PLAN.md §5:
/// `idle → capturing → annotating(k) → [next] → idle-with-open-session → … → composing → sending → idle`.
final class AppDelegate: NSObject, NSApplicationDelegate, OverlayViewDelegate {
    enum State: Equatable {
        case idle                       // with or without an open session (see store.isOpen)
        case capturing
        case annotating(screenIndex: Int)
        case composing
        case sending
    }

    private(set) var state: State = .idle {
        didSet { if oldValue != state { Log.info("state: \(oldValue) → \(state)") } }
    }

    private var statusItem: StatusItemController!
    private var hotKeys: HotKeyManager!
    private let store = SessionStore()
    private let capturer = ScreenCapturer()
    private let pasteTargets = PasteTargetTracker()
    private let updater = Updater()

    private var overlayWindow: OverlayWindow?
    private lazy var hub: HubWindowController = {
        let hub = HubWindowController(store: store)
        hub.onCopyPrompt = { [weak self] url in self?.recopyPrompt(from: url) }
        hub.onCopyFeedback = { [weak self] url in self?.recopyFeedback(from: url) }
        return hub
    }()
    private var composePanel: ComposePanel?
    /// The app to hand focus (and the paste) back to. Captured before we activate ourselves.
    private var previousApp: NSRunningApplication?
    private var composeReturnsToOverlay = false
    /// Browser probes still in flight, and what to run once they all land (see `send`).
    private var pendingProbes = 0
    private var probeWaiters: [() -> Void] = []

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched (bundle: \(Bundle.main.bundleIdentifier ?? "none"))")
        Log.info("screen recording preflight: \(Permissions.hasScreenCapture() ? "granted" : "not granted"); accessibility: \(Permissions.hasAccessibility() ? "granted" : "not granted")")

        store.pruneOldSessions(keep: 20)

        statusItem = StatusItemController(showsUpdates: Updater.isConfigured)
        statusItem.onCapture = { [weak self] in self?.captureHotKey() }
        statusItem.onSend = { [weak self] in self?.sendHotKey() }
        statusItem.onDiscard = { [weak self] in self?.discardSessionFromMenu() }
        statusItem.onRecentSelected = { [weak self] url in self?.recopyPrompt(from: url) }
        statusItem.onSessions = { [weak self] in self?.hub.present() }
        statusItem.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
        statusItem.recentSessionsProvider = { [weak self] in self?.store.recentSessions(limit: 10) ?? [] }
        statusItem.onQuit = { NSApp.terminate(nil) }

        hotKeys = HotKeyManager()
        hotKeys.register(.capture, keyCode: kVK_ANSI_A, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.captureHotKey()
        }
        hotKeys.register(.send, keyCode: kVK_Return, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.sendHotKey()
        }

        capturer.prefetch()
        installDebugHooks()
        offerResumeIfNeeded()
        refreshStatus()
    }

    // MARK: - Debug hooks (Scripts/debug.sh)

    /// Local-only automation for screenshots and smoke tests. Enabled with
    /// `defaults write com.gabe.annotation-station debugHooks -bool true`.
    private func installDebugHooks() {
        guard UserDefaults.standard.bool(forKey: "debugHooks") else { return }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleDebug(_:)),
            name: Notification.Name("com.gabe.annotation-station.debug"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        Log.info("debug hooks enabled")
    }

    @objc private func handleDebug(_ note: Notification) {
        let action = note.userInfo?["action"] as? String ?? ""
        Log.info("debug: \(action)")
        switch action {
        case "capture":
            captureHotKey()
        case "demo":
            overlayWindow?.overlayView.loadDemoMarks()
        case "snapshot":
            guard let path = note.userInfo?["path"] as? String, !path.isEmpty,
                  let screen = overlayWindow?.targetScreen ?? ScreenCapturer.screenUnderCursor() else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let capture = try await capturer.capture(screen: screen)
                    try Renderer.writePNG(capture.image, to: URL(fileURLWithPath: path))
                    Log.info("debug: snapshot written to \(path)")
                } catch {
                    Log.error("debug: snapshot failed: \(error.localizedDescription)")
                }
            }
        case "discard":
            if case .annotating(let index) = state {
                destroyOverlay()
                store.removeScreen(index: index)
                state = .idle
                refreshStatus()
            }
        case "mode":
            // Same path the toolbar picker takes, so a scripted run exercises the real thing.
            let mode = CaptureMode(rawValue: note.userInfo?["path"] as? String ?? "") ?? .llm
            store.setMode(mode)
            overlayWindow?.overlayView.setMode(mode)
        case "hub":
            hub.present()
        case "view":
            hub.openNewestSession()
        case "next":
            nextScreen()
        case "compose":
            if case .annotating = state, let window = overlayWindow {
                overlayDidRequestCompose(window.overlayView)
            }
        case "send":
            if case .annotating = state {
                destroyOverlay()
                send()
            }
        default:
            Log.error("debug: unknown action '\(action)'")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("terminating")
    }

    private func refreshStatus() {
        statusItem.update(sessionOpen: store.isOpen, badge: store.badge)
    }

    private func offerResumeIfNeeded() {
        guard let (session, dir) = store.resumableSession() else { return }
        let alert = NSAlert()
        alert.messageText = "Resume the unfinished session?"
        alert.informativeText = "\(session.id) has \(session.screens.count) screen(s) and \(session.markCount) mark(s). Resume to add screens or send it; Discard deletes it."
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Discard")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.resume(session, directory: dir)
        } else {
            store.discardResumable()
        }
        refreshStatus()
    }

    // MARK: - Hotkeys (routed through the state machine; PLAN.md §7)

    /// ⌘⇧A: capture from idle; "next screen" while annotating.
    private func captureHotKey() {
        switch state {
        case .idle: startCapture()
        case .annotating: nextScreen()
        case .capturing, .composing, .sending: Log.info("capture ignored while \(state)")
        }
    }

    /// ⌘⇧⏎: open compose from anywhere; while annotating it's the same as ⏎.
    private func sendHotKey() {
        switch state {
        case .idle:
            guard store.isOpen else { Log.info("send ignored: no open session"); return }
            rememberFrontmost()
            openCompose(returnToOverlay: false)
        case .annotating:
            overlayDidRequestCompose(overlayWindow!.overlayView)
        case .capturing, .composing, .sending:
            Log.info("send ignored while \(state)")
        }
    }

    private func rememberFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
            Log.info("frontmost app: \(front.bundleIdentifier ?? "?")")
        }
    }

    private func restoreFocus() {
        guard let app = previousApp else { return }
        app.activate(from: .current, options: [])
    }

    // MARK: - Capture → overlay

    private func startCapture() {
        Log.info("capture")
        guard ensureScreenCapturePermission() else { return }
        guard let screen = ScreenCapturer.screenUnderCursor() else {
            Log.error("no screen under cursor")
            return
        }
        rememberFrontmost()
        state = .capturing
        let t0 = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let capture = try await capturer.capture(screen: screen)
                captureFinished(capture, startedAt: t0)
            } catch {
                Log.error("capture failed: \(error.localizedDescription)")
                state = .idle
                restoreFocus()
            }
        }
    }

    private func captureFinished(_ capture: Capture, startedAt t0: Date) {
        do {
            try store.beginSessionIfNeeded()
            let screen = try store.addScreen(
                image: capture.image, displayID: capture.displayID,
                scale: capture.scale, pointSize: capture.pointSize
            )
            showOverlay(capture: capture, screen: screen)
            state = .annotating(screenIndex: screen.index)
            refreshStatus()
            Log.info("overlay visible \(SessionStore.ms(since: t0)) ms after hotkey (screen \(screen.index))")
            probeBrowser(for: screen.index)
        } catch {
            Log.error("starting screen: \(error.localizedDescription)")
            state = .idle
            restoreFocus()
        }
    }

    private func showOverlay(capture: Capture, screen: Screen) {
        let window = OverlayWindow(screen: capture.screen)
        window.setImage(capture.image)
        window.overlayView.delegate = self
        window.overlayView.configure(
            marks: screen.marks,
            numberOffset: store.session?.numberOffset(forScreenIndex: screen.index) ?? 0,
            screenIndex: screen.index
        )
        window.overlayView.setMode(store.session?.mode ?? .llm)
        overlayWindow = window
        window.present()
    }

    /// Ask the app we just captured what page it was showing. Fire-and-forget so the overlay is
    /// never held up: the answer lands on the screen record whenever it arrives.
    private func probeBrowser(for screenIndex: Int) {
        guard let app = previousApp, BrowserProbe.isBrowser(app) else { return }
        pendingProbes += 1
        BrowserProbe.context(for: app) { [weak self] context in
            guard let self else { return }
            if let context { store.setContext(screenIndex: screenIndex, context: context) }
            pendingProbes -= 1
            guard pendingProbes == 0 else { return }
            let waiters = probeWaiters
            probeWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// Runs `body` once every outstanding probe has answered, or after `timeout`, whichever is
    /// first. Only website sends wait: the very first probe of a browser costs a one-time
    /// Automation prompt, and a report that silently lost its URL is worse than a short pause.
    private func whenBrowserProbesSettle(timeout: TimeInterval, _ body: @escaping () -> Void) {
        guard pendingProbes > 0 else { body(); return }
        Log.info("waiting up to \(Int(timeout * 1000)) ms for \(pendingProbes) browser probe(s)")
        var fired = false
        let once = {
            guard !fired else { return }
            fired = true
            body()
        }
        probeWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: once)
    }

    private func hideOverlay() {
        overlayWindow?.overlayView.commitOpenNote()
        overlayWindow?.orderOut(nil)
    }

    private func destroyOverlay() {
        hideOverlay()
        overlayWindow = nil
    }

    private func ensureScreenCapturePermission() -> Bool {
        if Permissions.hasScreenCapture() { return true }
        Log.info("screen recording: not granted; requesting")
        let granted = Permissions.requestScreenCapture()
        if !granted {
            Log.info("screen recording: still not granted. Grant it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch")
        }
        return granted
    }

    // MARK: - OverlayViewDelegate

    func overlayMarksDidChange(_ view: OverlayView) {
        guard case .annotating(let index) = state else { return }
        store.updateMarks(screenIndex: index, marks: view.marks)
        refreshStatus()
    }

    func overlayDidRequestCompose(_ view: OverlayView) {
        guard case .annotating = state else { return }
        hideOverlay()
        openCompose(returnToOverlay: true)
    }

    func overlayDidRequestSendNow(_ view: OverlayView) {
        guard case .annotating = state else { return }
        destroyOverlay()
        send()
    }

    func overlayDidRequestNextScreen(_ view: OverlayView) {
        nextScreen()
    }

    /// The switch in the overlay toolbar is the authoritative choice: ⌘⏎ sends straight from
    /// here without ever opening the compose panel.
    func overlayDidChangeMode(_ view: OverlayView, to mode: CaptureMode) {
        store.setMode(mode)
        Log.info("mode set to \(mode.rawValue) from the overlay")
    }

    func overlayDidRequestDiscardScreen(_ view: OverlayView) {
        guard case .annotating(let index) = state, let window = overlayWindow else { return }
        let count = view.marks.count
        confirm(
            needed: count > 0,
            title: "Discard this screen?",
            message: "\(count) mark\(count == 1 ? "" : "s") on this screen will be lost.",
            button: "Discard Screen",
            on: window
        ) { [weak self] ok in
            guard let self, ok else { return }
            let screen = overlayWindow?.targetScreen
            destroyOverlay()
            store.removeScreen(index: index)
            state = .idle
            refreshStatus()
            restoreFocus()
            Toast.show(store.isOpen ? "Screen \(index) discarded · session keeps \(store.badge)" : "Screen discarded",
                       symbol: "trash", on: screen)
        }
    }

    func overlayDidRequestDiscardSession(_ view: OverlayView) {
        guard case .annotating = state, let window = overlayWindow, let session = store.session else { return }
        confirm(
            needed: true,
            title: "Discard the whole session?",
            message: "\(session.screens.count) screen(s) and \(session.markCount) mark(s) will be deleted.",
            button: "Discard Session",
            on: window
        ) { [weak self] ok in
            guard let self, ok else { return }
            let screen = overlayWindow?.targetScreen
            destroyOverlay()
            store.discardSession()
            state = .idle
            refreshStatus()
            restoreFocus()
            Toast.show("Session discarded", symbol: "trash", on: screen)
        }
    }

    /// Commit the current screen (marks are already saved), hide, and hand focus back so the
    /// user can navigate to the next screen. The session stays open.
    private func nextScreen() {
        guard case .annotating(let index) = state else { return }
        let screen = overlayWindow?.targetScreen
        destroyOverlay()
        state = .idle
        refreshStatus()
        restoreFocus()
        Log.info("screen \(index) committed; session now \(store.badge)")
        let marks = store.session?.markCount ?? 0
        Toast.show("Screen \(index) saved · \(marks) mark\(marks == 1 ? "" : "s") so far\n⌘⇧A to capture the next screen · ⌘⇧⏎ to send",
                   symbol: "checkmark.circle.fill", on: screen, duration: 3)
    }

    private func discardSessionFromMenu() {
        guard state == .idle, store.isOpen, let session = store.session else { return }
        let alert = NSAlert()
        alert.messageText = "Discard the open session?"
        alert.informativeText = "\(session.screens.count) screen(s) and \(session.markCount) mark(s) will be deleted."
        alert.addButton(withTitle: "Discard Session")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.discardSession()
            refreshStatus()
        }
    }

    /// Sheet-style confirmation on the overlay (a plain modal would sit under the .screenSaver window).
    private func confirm(needed: Bool, title: String, message: String, button: String, on window: NSWindow, completion: @escaping (Bool) -> Void) {
        guard needed else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    // MARK: - Compose

    private func openCompose(returnToOverlay: Bool) {
        guard let session = store.session else { return }
        let screen = overlayWindow?.targetScreen ?? ScreenCapturer.screenUnderCursor() ?? NSScreen.main!
        let previousState = state
        state = .composing
        composeReturnsToOverlay = returnToOverlay

        let panel = ComposePanel(session: session, on: screen)
        panel.onSend = { [weak self] mode, instruction, notes in
            guard let self else { return }
            store.setMode(mode)
            store.setInstruction(instruction)
            for (id, note) in notes { store.setNote(markID: id, note: note) }
            composePanel = nil
            destroyOverlay()
            send()
        }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            composePanel = nil
            if composeReturnsToOverlay, let window = overlayWindow, case .annotating = previousState {
                state = previousState
                window.present()
            } else {
                state = .idle
                restoreFocus()
            }
        }
        composePanel = panel
        panel.present()
    }

    // MARK: - Send

    private func send() {
        guard let mode = store.session?.mode else { return }
        state = .sending
        if mode == .website {
            whenBrowserProbesSettle(timeout: 1.5) { [weak self] in self?.finalizeAndDeliver() }
        } else {
            finalizeAndDeliver()
        }
    }

    private func finalizeAndDeliver() {
        let t0 = Date()
        store.finalize { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let delivery):
                switch delivery.mode {
                case .llm: Clipboard.copy(delivery.text)
                case .website: Clipboard.copy(delivery.text, attaching: delivery.images)
                }
                Log.info("\(delivery.mode.rawValue) document on clipboard (\(delivery.text.count) chars) \(SessionStore.ms(since: t0)) ms after send")
                state = .idle
                refreshStatus()
                switch delivery.mode {
                case .llm: deliverToAgent()
                case .website: deliverFeedback(delivery)
                }
            case .failure(let error):
                Log.error("send failed: \(error.localizedDescription)")
                state = .idle
                refreshStatus()
                let alert = NSAlert(error: error)
                alert.runModal()
                restoreFocus()
            }
        }
    }

    /// Website feedback goes to a person, not an agent: leave it on the clipboard, hand focus
    /// straight back to the browser being reviewed, and say where the rendered file is.
    private func deliverFeedback(_ delivery: SessionStore.Delivery) {
        let annotated = previousApp
        previousApp = nil
        annotated?.activate(from: .current, options: [])
        NSSound(named: "Glass")?.play()
        let images = delivery.images.count
        Toast.show("Feedback + \(images) annotated image\(images == 1 ? "" : "s") copied · paste into Slack, Linear or a doc",
                   symbol: "text.badge.checkmark", duration: 3)
    }

    /// Paste into the most recently used running agent app (Claude Desktop or Ghostty),
    /// bringing it to the front wherever it is. No agent running → copy only and hand focus
    /// back to the annotated app. Either way, make a sound.
    private func deliverToAgent() {
        let annotated = previousApp
        previousApp = nil
        if let target = pasteTargets.currentTarget() {
            Log.info("paste target: \(target.bundleIdentifier ?? "?")")
            AutoPaste.paste(into: target) { [weak self] outcome in
                switch outcome {
                case .pasted(let name):
                    Log.info("pasted into \(name)")
                    NSSound(named: "Pop")?.play()
                    Toast.show("Pasted into \(name)", symbol: "paperplane.fill")
                case .copiedOnly(let reason):
                    Log.info("copied only: \(reason)")
                    NSSound(named: "Tink")?.play()
                    Toast.show("Copied to clipboard · \(reason)", symbol: "doc.on.clipboard")
                    if !Permissions.hasAccessibility() { self?.showAccessibilityHint() }
                }
            }
        } else {
            Log.info("copied only: no Claude Desktop or Ghostty is running")
            annotated?.activate(from: .current, options: [])
            NSSound(named: "Tink")?.play()
            Toast.show("Copied to clipboard · open Claude Desktop or Ghostty to auto-paste", symbol: "doc.on.clipboard")
        }
    }

    private var accessibilityHintShown = false

    /// One-line explanation the first time a paste is skipped for lack of Accessibility.
    private func showAccessibilityHint() {
        guard !accessibilityHintShown else { return }
        accessibilityHintShown = true
        let alert = NSAlert()
        alert.messageText = "Prompt copied. Auto-paste needs Accessibility."
        alert.informativeText = "Annotation Station presses ⌘V in Claude Desktop or Ghostty for you. Allow it under System Settings › Privacy & Security › Accessibility. Until then, paste with ⌘V yourself."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func recopyFeedback(from directory: URL) {
        guard let feedback = SessionStore.feedback(in: directory) else {
            Log.error("no \(FeedbackComposer.fileName) in \(directory.lastPathComponent)")
            return
        }
        Clipboard.copy(feedback)
        NSSound(named: "Tink")?.play()
        Toast.show("Feedback copied from \(directory.lastPathComponent)", symbol: "doc.on.clipboard")
        Log.info("re-copied feedback from \(directory.lastPathComponent)")
    }

    private func recopyPrompt(from directory: URL) {
        guard let prompt = SessionStore.prompt(in: directory) else {
            Log.error("no prompt.md in \(directory.lastPathComponent)")
            return
        }
        Clipboard.copy(prompt)
        NSSound(named: "Tink")?.play()
        Toast.show("Prompt copied from \(directory.lastPathComponent)", symbol: "doc.on.clipboard")
        Log.info("re-copied prompt from \(directory.lastPathComponent)")
    }
}
