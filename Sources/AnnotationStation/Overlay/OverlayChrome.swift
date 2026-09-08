import AppKit

/// Shared look for the overlay's floating HUD pieces (toolbar, title, note editor).
class HUDPanelView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        appearance = NSAppearance(named: .vibrantDark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pin `content` to the edges and size ourselves to fit it.
    func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(content.fittingSize)
    }
}

/// "Screen 2 · 3 marks in session · next mark [4]" at the top of the overlay.
final class OverlayTitleBar: HUDPanelView {
    private let label = NSTextField(labelWithString: "")
    private let stack: NSStackView

    override init(frame: NSRect) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = .white
        stack = NSStackView(views: [icon, label])
        super.init(frame: frame)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        install(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(screenIndex: Int, totalMarks: Int, nextNumber: Int) {
        let marks = totalMarks == 1 ? "1 mark" : "\(totalMarks) marks"
        label.stringValue = "Screen \(screenIndex)   ·   \(marks) in session   ·   next mark [\(nextNumber)]"
        setFrameSize(stack.fittingSize)
    }
}

/// Bottom toolbar: tool picker plus the four ways out of the overlay. Buttons carry no key
/// equivalents on purpose (they would steal ⏎/⎋ from the note field); the overlay's keyDown
/// handles keys and the buttons call the same actions.
final class OverlayToolbar: HUDPanelView {
    var onTool: ((OverlayView.Tool) -> Void)?
    var onDiscard: (() -> Void)?
    var onNext: (() -> Void)?
    var onCompose: (() -> Void)?
    var onSend: (() -> Void)?
    var onMode: ((CaptureMode) -> Void)?

    private let segmented = NSSegmentedControl()
    private let modeSwitch = NSSwitch()
    private let send: NSButton
    private let hint = NSTextField(labelWithString: "⇧ square / 45°   ·   click a mark to select, drag to move, drag a corner or arrowhead to reshape   ·   ⌫ delete   ·   ⌘Z undo   ·   ⇥ cycle")

    override init(frame: NSRect) {
        send = NSButton()
        super.init(frame: frame)

        segmented.segmentCount = 2
        segmented.setImage(NSImage(systemSymbolName: "rectangle", accessibilityDescription: "Box"), forSegment: 0)
        segmented.setLabel("Box", forSegment: 0)
        segmented.setToolTip("Draw boxes with left-drag (B)", forSegment: 0)
        segmented.setImage(NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Arrow"), forSegment: 1)
        segmented.setLabel("Arrow", forSegment: 1)
        segmented.setToolTip("Draw arrows with left-drag (A). Right-drag or ⌥-drag always draws an arrow.", forSegment: 1)
        segmented.segmentStyle = .rounded
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(toolChanged(_:))

        let keys = NSTextField(labelWithString: "B / A")
        keys.font = NSFont.systemFont(ofSize: 11)
        keys.textColor = .secondaryLabelColor

        let discard = makeButton("Discard", symbol: "xmark", key: "⎋", action: #selector(discardTapped))
        discard.hasDestructiveAction = true
        discard.toolTip = "Discard this screen (⎋). ⌘⎋ discards the whole session."
        let next = makeButton("Next Screen", symbol: "plus.rectangle.on.rectangle", key: "N", action: #selector(nextTapped))
        next.toolTip = "Save this screen, hide the overlay, go annotate another screen (N or ⌘⇧A)"
        let compose = makeButton("Compose", symbol: "text.bubble", key: "⏎", action: #selector(composeTapped))
        compose.toolTip = "Add an overall instruction, then send (⏎)"
        configureButton(send, title: "Send", symbol: "paperplane.fill", key: "⌘⏎", action: #selector(sendTapped), prominent: true)

        // Where Send goes, decided here rather than in the compose panel — ⌘⏎ sends straight
        // from the overlay without ever opening compose, so the choice has to live where the
        // send button is. Off is the everyday path (Claude Code); on switches to a report.
        modeSwitch.target = self
        modeSwitch.action = #selector(modeToggled(_:))
        modeSwitch.controlSize = .small
        let modeLabel = NSTextField(labelWithString: "Website feedback")
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .labelColor
        let modeGroup = NSStackView(views: [modeSwitch, modeLabel])
        modeGroup.orientation = .horizontal
        modeGroup.spacing = 7
        modeGroup.toolTip = "Off: send the prompt to Claude Code. On: write a shareable feedback report with the page and browser you annotated."

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let modeSeparator = NSBox()
        modeSeparator.boxType = .separator
        modeSeparator.translatesAutoresizingMaskIntoConstraints = false
        modeSeparator.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let row = NSStackView(views: [segmented, keys, separator, discard, next, compose, modeSeparator, modeGroup, send])
        row.orientation = .horizontal
        row.spacing = 10
        row.setCustomSpacing(6, after: segmented)
        row.setCustomSpacing(14, after: keys)
        row.setCustomSpacing(14, after: separator)
        row.setCustomSpacing(14, after: compose)
        row.setCustomSpacing(14, after: modeGroup)
        setMode(.llm)

        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let column = NSStackView(views: [row, hint])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        install(column)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ tool: OverlayView.Tool) {
        segmented.selectedSegment = tool == .box ? 0 : 1
    }

    /// Reflect the session's mode, and say on the Send button itself where it is about to go —
    /// a switch alone is easy to leave flipped by accident.
    func setMode(_ mode: CaptureMode) {
        modeSwitch.state = mode == .website ? .on : .off
        switch mode {
        case .llm:
            configureButton(send, title: "Send", symbol: "paperplane.fill", key: "⌘⏎", action: #selector(sendTapped), prominent: true)
            send.toolTip = "Copy the prompt and paste it into Claude Desktop or Ghostty (⌘⏎)"
        case .website:
            configureButton(send, title: "Send Feedback", symbol: "text.badge.checkmark", key: "⌘⏎", action: #selector(sendTapped), prominent: true)
            send.toolTip = "Write feedback.md with the page and browser details, and copy it (⌘⏎)"
        }
        // "Send Feedback" is wider than "Send", so the HUD has to re-fit around it.
        if let content = subviews.first { setFrameSize(content.fittingSize) }
    }

    private func makeButton(_ title: String, symbol: String, key: String, action: Selector, prominent: Bool = false) -> NSButton {
        let button = NSButton()
        configureButton(button, title: title, symbol: symbol, key: key, action: action, prominent: prominent)
        return button
    }

    private func configureButton(_ button: NSButton, title: String, symbol: String, key: String, action: Selector, prominent: Bool = false) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: prominent ? NSColor.white : NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: "  \(key)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: prominent ? NSColor.white.withAlphaComponent(0.75) : NSColor.secondaryLabelColor,
        ]))
        button.attributedTitle = text
        if prominent {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
    }

    @objc private func modeToggled(_ sender: NSSwitch) {
        let mode: CaptureMode = sender.state == .on ? .website : .llm
        setMode(mode)
        onMode?(mode)
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        onTool?(sender.selectedSegment == 0 ? .box : .arrow)
    }

    @objc private func discardTapped() { onDiscard?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func composeTapped() { onCompose?() }
    @objc private func sendTapped() { onSend?() }
}
