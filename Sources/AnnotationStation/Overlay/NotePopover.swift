import AppKit

/// The mark's number badge, drawn by the same code that burns it into the PNG so the editor
/// and the screenshot can never disagree about how a badge looks.
final class BadgeView: NSView {
    private let number: Int

    init(number: Int) {
        self.number = number
        super.init(frame: CGRect(origin: .zero, size: Renderer.badgeSize(for: number)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Renderer.badgeSize(for: number) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Renderer.drawBadge(number, at: CGPoint(x: bounds.midX, y: bounds.midY), in: ctx)
    }
}

/// Note editor anchored next to a mark. ⏎, ⇥ or Done commits; ⎋ cancels.
/// Lives as a subview of the overlay so focus handling stays inside one window.
final class NotePopover: HUDPanelView, NSTextFieldDelegate {
    static let size = CGSize(width: 460, height: 46)

    let markID: UUID
    let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var text: String { field.stringValue }

    /// Where we are in the hands-free flow (see `startDictation`).
    private enum Dictation {
        case off
        /// The dictation app is listening.
        case recording
        /// Told to stop; waiting for the transcript to be pasted in.
        case transcribing
    }

    private var dictation: Dictation = .off
    private var transcriptTimeout: DispatchWorkItem?
    private var transcriptSettle: DispatchWorkItem?
    private let done = NSButton()
    private let doneTitle = "Done"
    /// Long enough for a slow local model on a long note; short enough that a dictation app which
    /// never answers does not strand the note open forever.
    private static let transcriptTimeout: TimeInterval = 25
    /// A paste can land in more than one change notification. Commit once it has gone quiet.
    private static let transcriptSettle: TimeInterval = 0.35

    init(markID: UUID, number: Int, isArrow: Bool, text: String) {
        self.markID = markID
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        layer?.cornerRadius = 10
        layer?.borderColor = MarkStyle.color.withAlphaComponent(0.8).cgColor

        // Number badge, drawn by the renderer so it matches the one burned into the PNG.
        // An NSTextField label was wrong here: a label draws its text from the top of its
        // frame, so the numeral sat high in the circle rather than centred in it.
        let badge = BadgeView(number: number)
        let badgeSize = Renderer.badgeSize(for: number)
        badge.frame = CGRect(x: 12, y: (Self.size.height - badgeSize.height) / 2,
                             width: badgeSize.width, height: badgeSize.height)
        addSubview(badge)

        let x = badge.frame.maxX + 10
        done.title = doneTitle
        done.target = self
        done.action = #selector(doneTapped)
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        done.sizeToFit()
        done.frame.origin = CGPoint(x: Self.size.width - done.frame.width - 10, y: (Self.size.height - done.frame.height) / 2)
        addSubview(done)

        field.frame = CGRect(x: x, y: 13, width: done.frame.minX - x - 10, height: 20)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .white
        field.font = NSFont.systemFont(ofSize: 14)
        let placeholder = isArrow ? "What should move or relate here?   ⏎ done · ⎋ cancel" : "What about this region?   ⏎ done · ⎋ cancel"
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ])
        field.stringValue = text
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Hands-free dictation

    /// Start the dictation app listening, so a note can be spoken rather than typed.
    ///
    /// Called once the field is first responder: the transcript arrives as a paste, and a paste
    /// goes wherever the focus is. No-op unless a record hotkey is configured — see VoiceControl.
    func startDictation() {
        guard VoiceControl.isEnabled, dictation == .off else { return }
        guard VoiceControl.toggleRecording() else { return }
        dictation = .recording
        Log.info("voice: recording for note \(markID)")
    }

    /// Stop the dictation app and leave the note open until the transcript lands.
    ///
    /// ⏎ cannot simply commit here: transcription finishes *after* the stop, so committing now
    /// would close the field and the paste would land in whatever is underneath.
    private func stopDictationAndWait() {
        VoiceControl.toggleRecording()
        dictation = .transcribing
        done.title = "Transcribing…"
        done.isEnabled = false
        Log.info("voice: stopped, waiting for the transcript")

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, dictation == .transcribing else { return }
            // Nothing came back. Hand the note back rather than committing something the user
            // never saw — they can type it, or press ⏎ again to commit what is there.
            dictation = .off
            done.title = doneTitle
            done.isEnabled = true
            Toast.show("No transcript arrived — type it, or press ⏎ to keep what's there",
                       symbol: "mic.slash", duration: 3)
            Log.info("voice: timed out waiting for the transcript")
        }
        transcriptTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcriptTimeout, execute: timeout)
    }

    /// Cancel any in-flight dictation. Safe to call whatever state we are in.
    func endDictation() {
        transcriptTimeout?.cancel()
        transcriptSettle?.cancel()
        if dictation != .off { VoiceControl.toggleRecording() }
        dictation = .off
    }

    func controlTextDidChange(_ notification: Notification) {
        guard dictation == .transcribing else { return }
        // The transcript may arrive in more than one change; commit once it has gone quiet.
        transcriptSettle?.cancel()
        let settle = DispatchWorkItem { [weak self] in
            guard let self, dictation == .transcribing else { return }
            transcriptTimeout?.cancel()
            dictation = .off
            Log.info("voice: transcript landed, committing note")
            onCommit?(field.stringValue)
        }
        transcriptSettle = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcriptSettle, execute: settle)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if dictation == .recording {
                stopDictationAndWait()
            } else {
                endDictation()
                onCommit?(field.stringValue)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endDictation()
            onCancel?()
            return true
        default:
            return false
        }
    }

    @objc private func doneTapped() {
        if dictation == .recording {
            stopDictationAndWait()
        } else {
            endDictation()
            onCommit?(field.stringValue)
        }
    }

    // Clicks inside the popover must not start a drag on the overlay underneath.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}
