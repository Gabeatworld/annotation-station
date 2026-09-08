import AppKit

protocol OverlayViewDelegate: AnyObject {
    func overlayMarksDidChange(_ view: OverlayView)
    func overlayDidRequestCompose(_ view: OverlayView)
    func overlayDidRequestSendNow(_ view: OverlayView)
    func overlayDidChangeMode(_ view: OverlayView, to mode: CaptureMode)
    func overlayDidRequestNextScreen(_ view: OverlayView)
    func overlayDidRequestDiscardScreen(_ view: OverlayView)
    func overlayDidRequestDiscardSession(_ view: OverlayView)
}

/// Draws this screen's marks over the frozen capture and owns all mouse/keyboard input
/// while annotating. Coordinates are points with a top-left origin (`isFlipped`), which is
/// also what `Mark` stores, so no conversion happens here.
final class OverlayView: NSView {
    enum Tool { case box, arrow }

    weak var delegate: OverlayViewDelegate?

    private(set) var marks: [Mark] = []
    /// Marks on earlier screens of the session; the first mark here is `numberOffset + 1`.
    var numberOffset = 0
    var screenIndex = 1
    var tool: Tool = .box {
        didSet {
            toolbar.select(tool)
            needsDisplay = true
        }
    }
    private(set) var selectedID: UUID?

    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    private var drag: Drag = .none
    private var note: NotePopover?
    private var noteLabelRects: [UUID: CGRect] = [:]
    private var badgeRects: [UUID: CGRect] = [:]
    private var trackingArea: NSTrackingArea?

    let toolbar = OverlayToolbar()
    let titleBar = OverlayTitleBar()

    private enum Drag {
        case none
        case creating(tool: Tool, start: CGPoint, current: CGPoint, constrained: Bool)
        case moving(id: UUID, last: CGPoint, before: [Mark])
        case resizing(id: UUID, anchor: CGPoint, before: [Mark])
        case rerouting(id: UUID, end: MarkGeometry.ArrowEnd, before: [Mark])

        var before: [Mark]? {
            switch self {
            case .moving(_, _, let b), .resizing(_, _, let b), .rerouting(_, _, let b): return b
            default: return nil
            }
        }
    }

    // MARK: - Setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(titleBar)
        addSubview(toolbar)
        toolbar.onTool = { [weak self] in self?.tool = $0 }
        toolbar.onDiscard = { [weak self] in self.map { $0.delegate?.overlayDidRequestDiscardScreen($0) } }
        toolbar.onNext = { [weak self] in self.map { $0.delegate?.overlayDidRequestNextScreen($0) } }
        toolbar.onCompose = { [weak self] in self.map { $0.delegate?.overlayDidRequestCompose($0) } }
        toolbar.onSend = { [weak self] in self.map { $0.delegate?.overlayDidRequestSendNow($0) } }
        toolbar.onMode = { [weak self] mode in
            guard let self else { return }
            delegate?.overlayDidChangeMode(self, to: mode)
            positionChrome()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(marks: [Mark], numberOffset: Int, screenIndex: Int) {
        self.marks = marks.sorted { $0.seq < $1.seq }
        self.numberOffset = numberOffset
        self.screenIndex = screenIndex
        undoStack = []
        redoStack = []
        selectedID = nil
        drag = .none
        closeNote()
        positionChrome()
        refreshTitle()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        positionChrome()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionChrome()
    }

    private func positionChrome() {
        guard bounds.width > 0 else { return }
        let menuBarHeight = window?.screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 25
        titleBar.setFrameOrigin(CGPoint(x: (bounds.width - titleBar.frame.width) / 2, y: menuBarHeight + 12))
        toolbar.setFrameOrigin(CGPoint(x: (bounds.width - toolbar.frame.width) / 2, y: bounds.maxY - toolbar.frame.height - 28))
    }

    /// Show the session's current send target in the toolbar switch.
    func setMode(_ mode: CaptureMode) {
        toolbar.setMode(mode)
        positionChrome()
    }

    private func refreshTitle() {
        titleBar.update(screenIndex: screenIndex, totalMarks: numberOffset + marks.count, nextNumber: nextNumber)
        positionChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Numbering

    private func number(at index: Int) -> Int { numberOffset + index + 1 }
    private var nextNumber: Int { numberOffset + marks.count + 1 }
    private var nextSeq: Int { (marks.map(\.seq).max() ?? 0) + 1 }
    private func index(of id: UUID) -> Int? { marks.firstIndex { $0.id == id } }
    private var selectedMark: Mark? { selectedID.flatMap { id in marks.first { $0.id == id } } }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var items: [Renderer.Item] = marks.enumerated().map { (kind: $1.kind, number: number(at: $0)) }
        if let kind = inProgressKind { items.append((kind: kind, number: nextNumber)) }
        Renderer.drawMarks(items, bounds: bounds, dimOutsideBoxes: true, in: ctx)
        if let mark = selectedMark { drawHandles(for: mark.kind, in: ctx) }
        drawNoteLabels(in: ctx)
    }

    private var inProgressKind: Mark.Kind? {
        guard case .creating(let tool, let start, let current, let constrained) = drag else { return nil }
        return kind(for: tool, from: start, to: current, constrained: constrained)
    }

    private func kind(for tool: Tool, from a: CGPoint, to b: CGPoint, constrained: Bool) -> Mark.Kind {
        switch tool {
        case .box: return .box(MarkGeometry.rect(from: a, to: b, square: constrained))
        case .arrow: return .arrow(from: a, to: constrained ? MarkGeometry.snappedToAngle(from: a, to: b) : b)
        }
    }

    private func drawHandles(for kind: Mark.Kind, in ctx: CGContext) {
        let points: [CGPoint]
        switch kind {
        case .box(let r): points = MarkGeometry.Corner.allCases.map { $0.point(in: r) }
        case .arrow(let a, let b): points = [a, b]
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        for p in points {
            let r = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
    }

    /// Each mark's note sits next to its badge ("Add note…" when empty). Click to edit.
    /// Layout and drawing live in Renderer so the overlay and the exported PNG agree.
    private func drawNoteLabels(in ctx: CGContext) {
        let items = marks.map { mark -> Renderer.ChipItem in
            let text = mark.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return Renderer.ChipItem(id: mark.id, kind: mark.kind,
                                     text: text.isEmpty ? "Add note…" : mark.note,
                                     isPlaceholder: text.isEmpty)
        }
        // The mark being edited has the popover over it; a chip underneath would just show through.
        let layout = Renderer.drawNoteChips(items, bounds: bounds, skipping: note?.markID, in: ctx)
        noteLabelRects = layout.chips
        badgeRects = layout.badges
    }

    // MARK: - Hit-testing helpers

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// Note label or badge under the point → that mark.
    private func noteHit(_ p: CGPoint) -> UUID? {
        for mark in marks.reversed() {
            if noteLabelRects[mark.id]?.contains(p) == true || badgeRects[mark.id]?.contains(p) == true { return mark.id }
        }
        return nil
    }

    /// True when the point is over the toolbar, title, or note editor (which handle their own events).
    private func isOverChrome(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        let hit = hitTest(superview.convert(event.locationInWindow, from: nil))
        return hit != nil && hit !== self
    }

    // MARK: - Cursor

    override func mouseEntered(with event: NSEvent) { updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }

    private func updateCursor(for event: NSEvent) {
        if isOverChrome(event) {
            NSCursor.arrow.set()
            return
        }
        cursor(at: point(for: event)).set()
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        switch drag {
        case .moving: return .closedHand
        case .creating: return .crosshair
        case .resizing(let id, _, _):
            if let m = marks.first(where: { $0.id == id }), case .box(let r) = m.kind,
               let corner = MarkGeometry.corner(of: r, near: p) { return resizeCursor(for: corner) }
            return .crosshair
        case .rerouting: return .crosshair
        case .none: break
        }
        if noteHit(p) != nil { return .pointingHand }
        if let sel = selectedMark {
            switch sel.kind {
            case .box(let r):
                if let corner = MarkGeometry.corner(of: r, near: p) { return resizeCursor(for: corner) }
            case .arrow(let a, let b):
                if MarkGeometry.arrowEnd(from: a, to: b, near: p) != nil { return endpointCursor() }
            }
        }
        if marks.contains(where: { MarkGeometry.hits($0.kind, p) }) { return .openHand }
        return .crosshair
    }

    private func resizeCursor(for corner: MarkGeometry.Corner) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch corner {
            case .topLeft: position = .topLeft
            case .topRight: position = .topRight
            case .bottomLeft: position = .bottomLeft
            case .bottomRight: position = .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return .crosshair
    }

    private func endpointCursor() -> NSCursor {
        if #available(macOS 15, *) { return NSCursor.frameResize(position: .topLeft, directions: .all) }
        return .crosshair
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitOpenNote()
        let p = point(for: event)
        let flags = event.modifierFlags
        let constrained = flags.contains(.shift)

        if let id = noteHit(p) {
            selectedID = id
            openNote(for: id)
            return
        }

        if flags.contains(.option) {
            selectedID = nil
            drag = .creating(tool: .arrow, start: p, current: p, constrained: constrained)
            needsDisplay = true
            NSCursor.crosshair.set()
            return
        }

        // Handles of the selected mark win over everything (reroute/resize beats move).
        if let sel = selectedMark {
            switch sel.kind {
            case .box(let r):
                if let corner = MarkGeometry.corner(of: r, near: p) {
                    drag = .resizing(id: sel.id, anchor: corner.opposite.point(in: r), before: marks)
                    return
                }
            case .arrow(let a, let b):
                if let end = MarkGeometry.arrowEnd(from: a, to: b, near: p) {
                    drag = .rerouting(id: sel.id, end: end, before: marks)
                    return
                }
            }
        }

        if let hit = marks.last(where: { MarkGeometry.hits($0.kind, p) }) {
            selectedID = hit.id
            needsDisplay = true
            if event.clickCount == 2 {
                drag = .none
                openNote(for: hit.id)
            } else {
                drag = .moving(id: hit.id, last: p, before: marks)
                NSCursor.closedHand.set()
            }
            return
        }

        selectedID = nil
        drag = .creating(tool: tool, start: p, current: p, constrained: constrained)
        needsDisplay = true
        NSCursor.crosshair.set()
    }

    override func mouseDragged(with event: NSEvent) { updateDrag(with: event) }

    override func mouseUp(with event: NSEvent) {
        updateDrag(with: event)
        finishDrag()
        updateCursor(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isOverChrome(event) else { super.rightMouseDown(with: event); return }
        commitOpenNote()
        selectedID = nil
        let p = point(for: event)
        drag = .creating(tool: .arrow, start: p, current: p, constrained: event.modifierFlags.contains(.shift))
        needsDisplay = true
        NSCursor.crosshair.set()
    }

    override func rightMouseDragged(with event: NSEvent) { updateDrag(with: event) }

    override func rightMouseUp(with event: NSEvent) {
        updateDrag(with: event)
        finishDrag()
        updateCursor(for: event)
    }

    private func updateDrag(with event: NSEvent) {
        let p = point(for: event)
        let constrained = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(let tool, let start, _, _):
            drag = .creating(tool: tool, start: start, current: p, constrained: constrained)
        case .moving(let id, let last, let before):
            if let i = index(of: id) {
                marks[i].kind = marks[i].kind.offset(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            }
            drag = .moving(id: id, last: p, before: before)
        case .resizing(let id, let anchor, _):
            if let i = index(of: id) {
                marks[i].kind = .box(MarkGeometry.rect(from: anchor, to: p, square: constrained))
            }
        case .rerouting(let id, let end, _):
            if let i = index(of: id), case .arrow(let a, let b) = marks[i].kind {
                switch end {
                case .head:
                    marks[i].kind = .arrow(from: a, to: constrained ? MarkGeometry.snappedToAngle(from: a, to: p) : p)
                case .tail:
                    marks[i].kind = .arrow(from: constrained ? MarkGeometry.snappedToAngle(from: b, to: p) : p, to: b)
                }
            }
        }
        needsDisplay = true
    }

    private func finishDrag() {
        let finished = drag
        drag = .none
        needsDisplay = true
        switch finished {
        case .none:
            return
        case .creating(let tool, let start, let current, let constrained):
            let kind = kind(for: tool, from: start, to: current, constrained: constrained)
            guard !MarkGeometry.isDegenerate(kind) else { return }
            pushUndo()
            let mark = Mark(seq: nextSeq, kind: kind)
            marks.append(mark)
            selectedID = mark.id
            marksChanged()
            openNote(for: mark.id)
        default:
            if let before = finished.before, before != marks {
                undoStack.append(before)
                redoStack.removeAll()
                marksChanged()
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)

        switch event.keyCode {
        case 36, 76: // return, keypad enter
            if cmd { delegate?.overlayDidRequestSendNow(self) } else { delegate?.overlayDidRequestCompose(self) }
            return
        case 53: // escape
            if cmd {
                delegate?.overlayDidRequestDiscardSession(self)
            } else if selectedID != nil {
                selectedID = nil
                needsDisplay = true
            } else {
                delegate?.overlayDidRequestDiscardScreen(self)
            }
            return
        case 51, 117: // delete, forward delete
            deleteSelected()
            return
        case 48: // tab
            cycleSelection(by: shift ? -1 : 1)
            return
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        if cmd {
            if chars == "z" {
                if shift { redo() } else { undo() }
            }
            return
        }
        switch chars {
        case "b": tool = .box
        case "a": tool = .arrow
        case "n": delegate?.overlayDidRequestNextScreen(self)
        default: break
        }
    }

    // MARK: - Editing

    private func marksChanged() {
        needsDisplay = true
        refreshTitle()
        delegate?.overlayMarksDidChange(self)
    }

    private func pushUndo() {
        undoStack.append(marks)
        redoStack.removeAll()
    }

    private func deleteSelected() {
        commitOpenNote()
        guard let id = selectedID, let i = index(of: id) else { return }
        pushUndo()
        marks.remove(at: i)          // numbers are derived → everything after renumbers itself
        selectedID = nil
        marksChanged()
    }

    private func cycleSelection(by step: Int) {
        guard !marks.isEmpty else { return }
        let current = selectedID.flatMap(index(of:)) ?? (step > 0 ? -1 : marks.count)
        let next = (current + step + marks.count) % marks.count
        selectedID = marks[next].id
        needsDisplay = true
    }

    private func undo() {
        commitOpenNote()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(marks)
        marks = previous
        validateSelection()
        marksChanged()
    }

    private func redo() {
        commitOpenNote()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        marks = next
        validateSelection()
        marksChanged()
    }

    private func validateSelection() {
        if let id = selectedID, index(of: id) == nil { selectedID = nil }
    }

    // MARK: - Demo (debug hook)

    /// Three marks that exercise every affordance: selected box, arrow, empty note being edited.
    func loadDemoMarks() {
        let w = bounds.width, h = bounds.height
        pushUndo()
        marks = [
            Mark(seq: 1, kind: .box(CGRect(x: w * 0.18, y: h * 0.24, width: w * 0.34, height: h * 0.30)), note: "Card grid is misaligned with the header"),
            Mark(seq: 2, kind: .arrow(from: CGPoint(x: w * 0.64, y: h * 0.64), to: CGPoint(x: w * 0.64, y: h * 0.38)), note: "Move the filter chips up into the toolbar"),
            Mark(seq: 3, kind: .box(CGRect(x: w * 0.60, y: h * 0.70, width: w * 0.22, height: h * 0.14)), note: ""),
        ]
        selectedID = marks[0].id
        marksChanged()
        openNote(for: marks[2].id)
    }

    // MARK: - Notes

    private func openNote(for id: UUID) {
        commitOpenNote()
        guard let i = index(of: id) else { return }
        let mark = marks[i]
        let popover = NotePopover(markID: id, number: number(at: i), isArrow: mark.kind.isArrow, text: mark.note)
        popover.setFrameOrigin(noteOrigin(for: mark.kind))
        popover.onCommit = { [weak self] text in self?.finishNote(id: id, text: text) }
        popover.onCancel = { [weak self] in self?.closeNote() }
        addSubview(popover)
        note = popover
        needsDisplay = true
        window?.makeFirstResponder(popover.field)
    }

    private func noteOrigin(for kind: Mark.Kind) -> CGPoint {
        let size = NotePopover.size
        var origin: CGPoint
        switch kind {
        case .box(let r):
            origin = CGPoint(x: r.minX, y: r.maxY + 12)
            if origin.y + size.height > bounds.maxY - 8 { origin.y = r.minY - size.height - 12 }
        case .arrow(let a, _):
            origin = CGPoint(x: a.x + 18, y: a.y + 22)
        }
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, 8), bounds.maxY - size.height - 8)
        return origin
    }

    private func finishNote(id: UUID, text: String) {
        if let i = index(of: id), marks[i].note != text {
            pushUndo()
            marks[i].note = text
            marksChanged()
        }
        closeNote()
    }

    /// Commit whatever is in the open note field (used before any other interaction).
    func commitOpenNote() {
        guard let popover = note else { return }
        finishNote(id: popover.markID, text: popover.text)
    }

    private func closeNote() {
        guard let popover = note else { return }
        note = nil
        window?.makeFirstResponder(self)
        popover.removeFromSuperview()
        needsDisplay = true
    }
}
