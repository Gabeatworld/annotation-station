import AppKit

/// Note editor anchored next to a mark. ⏎, ⇥ or Done commits; ⎋ cancels.
/// Lives as a subview of the overlay so focus handling stays inside one window.
final class NotePopover: HUDPanelView, NSTextFieldDelegate {
    static let size = CGSize(width: 460, height: 46)

    let markID: UUID
    let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    var text: String { field.stringValue }

    init(markID: UUID, number: Int, isArrow: Bool, text: String) {
        self.markID = markID
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        layer?.cornerRadius = 10
        layer?.borderColor = MarkStyle.color.withAlphaComponent(0.8).cgColor

        // Number badge, matching the mark's own badge.
        let badge = NSTextField(labelWithString: "\(number)")
        badge.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = MarkStyle.color.cgColor
        badge.layer?.cornerRadius = 11
        badge.frame = CGRect(x: 12, y: 12, width: max(22, badge.fittingSize.width + 10), height: 22)
        addSubview(badge)

        let x = badge.frame.maxX + 10
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            onCommit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    @objc private func doneTapped() { onCommit?(field.stringValue) }

    // Clicks inside the popover must not start a drag on the overlay underneath.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}
