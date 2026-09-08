import AppKit

/// Floating panel for the overall instruction plus every mark's note, grouped by screen.
/// ⌘⏎ sends, ⎋ goes back. Optional: `⌘⏎` from the overlay skips it entirely (PLAN.md §2).
final class ComposePanel: NSPanel, NSWindowDelegate {
    var onSend: ((_ mode: CaptureMode, _ instruction: String, _ notes: [UUID: String]) -> Void)?
    var onCancel: (() -> Void)?

    private let textView: NSTextView
    private let modeControl: NSSegmentedControl
    private var noteFields: [(UUID, NSTextField)] = []
    private var finished = false

    init(session: Session, on screen: NSScreen) {
        let width: CGFloat = 580
        let margin: CGFloat = 16
        let container = FlippedView()
        var y: CGFloat = margin

        func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .semibold, color: NSColor = .secondaryLabelColor) {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.frame = CGRect(x: margin, y: y, width: width - 2 * margin, height: 17)
            container.addSubview(l)
            y += 21
        }

        label("Instruction (optional) — relational asks that don't belong to one mark")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = CGRect(x: margin, y: y, width: width - 2 * margin, height: 96)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = CGSize(width: 6, height: 6)
        tv.string = session.instruction
        textView = tv
        container.addSubview(scroll)
        y += 96 + 12

        // Mark rows in their own (flipped) view so they can scroll when there are many.
        let numbered = session.numberedMarks
        var fields: [(UUID, NSTextField)] = []
        if !numbered.isEmpty {
            label("Marks")
            let rows = FlippedView()
            var ry: CGFloat = 0
            var lastScreen = 0
            let multiScreen = Set(numbered.map(\.screenIndex)).count > 1
            for item in numbered {
                if multiScreen, item.screenIndex != lastScreen {
                    let l = NSTextField(labelWithString: "Screen \(item.screenIndex)")
                    l.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                    l.textColor = .tertiaryLabelColor
                    l.frame = CGRect(x: 0, y: ry + 2, width: 200, height: 15)
                    rows.addSubview(l)
                    ry += 19
                    lastScreen = item.screenIndex
                }
                let tag = NSTextField(labelWithString: item.mark.kind.isArrow ? "[\(item.number)] ↗" : "[\(item.number)]")
                tag.font = NSFont.systemFont(ofSize: 13, weight: .bold)
                tag.textColor = MarkStyle.color
                tag.frame = CGRect(x: 0, y: ry + 3, width: 60, height: 18)
                rows.addSubview(tag)
                let field = NSTextField(string: item.mark.note)
                field.placeholderString = item.mark.kind.isArrow ? "What should move / relate here?" : "What about this region?"
                field.font = NSFont.systemFont(ofSize: 13)
                field.frame = CGRect(x: 66, y: ry, width: width - 2 * margin - 66, height: 24)
                rows.addSubview(field)
                fields.append((item.mark.id, field))
                ry += 30
            }
            rows.frame = CGRect(x: 0, y: 0, width: width - 2 * margin, height: ry)
            let maxRowsHeight: CGFloat = 300
            if ry > maxRowsHeight {
                let rowsScroll = NSScrollView(frame: CGRect(x: margin, y: y, width: width - 2 * margin, height: maxRowsHeight))
                rowsScroll.hasVerticalScroller = true
                rowsScroll.drawsBackground = false
                rowsScroll.documentView = rows
                container.addSubview(rowsScroll)
                y += maxRowsHeight
            } else {
                rows.frame.origin = CGPoint(x: margin, y: y)
                container.addSubview(rows)
                y += ry
            }
            y += 8
        }
        noteFields = fields

        // Mode row: which document Send produces (ROADMAP "feedback types").
        let modeLabel = NSTextField(labelWithString: "Send as")
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.frame = CGRect(x: margin, y: y + 4, width: 60, height: 17)
        container.addSubview(modeLabel)

        // Same icon+label picker as the overlay toolbar, in the same order — this panel only
        // mirrors a choice that can equally be made out there.
        let modes = CaptureMode.pickerOrder
        let picker = NSSegmentedControl()
        picker.segmentCount = modes.count
        for (index, mode) in modes.enumerated() {
            picker.setImage(NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title), forSegment: index)
            picker.setLabel(mode.shortTitle, forSegment: index)
            picker.setToolTip(mode.pickerToolTip, forSegment: index)
        }
        picker.segmentStyle = .rounded
        picker.trackingMode = .selectOne
        picker.selectedSegment = modes.firstIndex(of: session.mode) ?? 0
        picker.frame = CGRect(x: margin + 66, y: y, width: 200, height: 24)
        container.addSubview(picker)
        modeControl = picker
        y += 28

        if let context = session.primaryContext {
            var parts = [context.shortURL, context.browserName]
            if let v = context.viewport { parts.append("\(Int(v.width)) × \(Int(v.height)) CSS px") }
            label(parts.joined(separator: "  ·  "), size: 11, weight: .regular, color: .tertiaryLabelColor)
        } else {
            picker.toolTip = "No page details were captured — a browser wasn't frontmost, or Automation is off for it. Website feedback still carries the screenshots and notes."
            y += 4
        }

        let hint = NSTextField(labelWithString: "⌘⏎ send  ·  ⎋ back")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = CGRect(x: margin, y: y + 8, width: 200, height: 15)
        container.addSubview(hint)

        let cancel = NSButton(title: "Back", target: nil, action: #selector(cancelTapped(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = CGRect(x: width - margin - 200, y: y, width: 90, height: 32)
        container.addSubview(cancel)

        let send = NSButton(title: "Send", target: nil, action: #selector(sendTapped(_:)))
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = [.command]
        send.frame = CGRect(x: width - margin - 100, y: y, width: 100, height: 32)
        container.addSubview(send)
        y += 32 + margin

        let contentRect = NSRect(x: 0, y: 0, width: width, height: y)
        super.init(contentRect: contentRect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        cancel.target = self
        send.target = self
        container.frame = contentRect
        contentView = container

        title = "Annotation Station — Compose"
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        delegate = self

        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
    }

    @objc private func sendTapped(_ sender: Any?) {
        guard !finished else { return }
        finished = true
        var notes: [UUID: String] = [:]
        for (id, field) in noteFields { notes[id] = field.stringValue }
        let instruction = textView.string
        let modes = CaptureMode.pickerOrder
        let mode = modes.indices.contains(modeControl.selectedSegment) ? modes[modeControl.selectedSegment] : .llm
        orderOut(nil)
        onSend?(mode, instruction, notes)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelTapped(nil)
        return false
    }
}
