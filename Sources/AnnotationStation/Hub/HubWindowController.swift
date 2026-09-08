import AppKit

/// "Sessions" window: every capture on disk, grouped by day, newest first. Each session card
/// shows thumbnails of its annotated screens, mark notes, and the actions that matter after
/// the fact: copy the prompt again, reveal the folder, delete.
final class HubWindowController: NSWindowController {
    var onCopyPrompt: ((URL) -> Void)?
    var onCopyFeedback: ((URL) -> Void)?
    private let store: SessionStore
    private let stack = NSStackView()
    private let footer = NSTextField(labelWithString: "")
    private let thumbnailQueue = DispatchQueue(label: "com.gabe.annotation-station.thumbnails", qos: .userInitiated)
    /// Held so the viewer window is not deallocated the moment it is shown.
    private var viewer: ScreenshotViewerController?

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Sessions"
        window.subtitle = "Annotation Station"
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SessionsHub")
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window, let content = window.contentView else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document

        let footerBar = NSVisualEffectView()
        footerBar.material = .titlebar
        footerBar.blendingMode = .withinWindow
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footer.font = NSFont.systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        let openFolder = NSButton(title: "Open Sessions Folder", target: self, action: #selector(openFolder))
        openFolder.bezelStyle = .rounded
        openFolder.controlSize = .small
        openFolder.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(separator)
        footerBar.addSubview(footer)
        footerBar.addSubview(openFolder)

        content.addSubview(scroll)
        content.addSubview(footerBar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            footerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 40),
            separator.topAnchor.constraint(equalTo: footerBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            footer.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 24),
            footer.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
            openFolder.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -20),
            openFolder.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    // MARK: - Data

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let sessions = store.allSessions()
        footer.stringValue = "\(sessions.count) session\(sessions.count == 1 ? "" : "s")  ·  newest 20 are kept  ·  \(store.sessionsDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"

        guard !sessions.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No sessions yet.\nPress ⌘⇧A anywhere to capture the screen under your cursor.")
            empty.font = NSFont.systemFont(ofSize: 14)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            stack.addArrangedSubview(empty)
            stack.alignment = .centerX
            return
        }
        stack.alignment = .leading

        let calendar = Calendar.current
        var currentDay: Date?
        for summary in sessions {
            let day = calendar.startOfDay(for: summary.session.createdAt)
            if day != currentDay {
                currentDay = day
                let header = NSTextField(labelWithString: Self.dayFormatter.string(from: day))
                header.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
                if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!) }
                stack.addArrangedSubview(header)
            }
            let card = makeCard(for: summary)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
    }

    // MARK: - Cards

    private func makeCard(for summary: SessionStore.Summary) -> NSView {
        let session = summary.session
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle

        // Thumbnails row (one per screen, capped at four).
        let thumbs = NSStackView()
        thumbs.orientation = .horizontal
        thumbs.spacing = 8
        let screens = session.orderedScreens
        for screen in screens.prefix(4) {
            let annotated = summary.directory.appendingPathComponent("screen-\(screen.index)-annotated.png")
            let raw = summary.directory.appendingPathComponent("screen-\(screen.index).png")
            let url = FileManager.default.fileExists(atPath: annotated.path) ? annotated : raw
            let ratio = screen.pointSize.height / max(screen.pointSize.width, 1)
            let index = screen.index
            let thumb = ThumbnailView(size: NSSize(width: 176, height: max(80, 176 * ratio))) { [weak self] in
                self?.openViewer(for: summary, startAt: index)
            }
            thumb.toolTip = "Open screen \(index) with its marks"
            thumbs.addArrangedSubview(thumb)
            loadThumbnail(url, into: thumb)
        }
        if screens.count > 4 {
            let more = NSTextField(labelWithString: "+\(screens.count - 4) more")
            more.textColor = .secondaryLabelColor
            thumbs.addArrangedSubview(more)
        }

        // Text column.
        let title = NSTextField(labelWithString: "")
        let time = Self.timeFormatter.string(from: session.createdAt)
        let counts = "\(screens.count) screen\(screens.count == 1 ? "" : "s") · \(session.markCount) mark\(session.markCount == 1 ? "" : "s")"
        title.stringValue = "\(time)   ·   \(counts)"
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        var statusText = summary.isOpen ? "In progress" : (summary.isFinished ? "Sent" : "Not sent")
        if session.mode != .llm { statusText += "  ·  \(session.mode.title)" }
        let status = NSTextField(labelWithString: statusText)
        status.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        status.textColor = summary.isOpen ? .systemOrange : (summary.isFinished ? .systemGreen : .secondaryLabelColor)

        let notesText = session.numberedMarks.map { item in
            let note = item.mark.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(item.number)]\(item.mark.kind.isArrow ? " ↗" : "") \(note.isEmpty ? "—" : note)"
        }.joined(separator: "    ")
        let notes = NSTextField(wrappingLabelWithString: notesText.isEmpty ? "No marks" : notesText)
        notes.font = NSFont.systemFont(ofSize: 12)
        notes.textColor = .secondaryLabelColor
        notes.maximumNumberOfLines = 3

        let column = NSStackView(views: [title, status, notes])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        if let context = session.primaryContext {
            let page = NSTextField(labelWithString: "\(context.shortURL)  ·  \(context.browserName)")
            page.font = NSFont.systemFont(ofSize: 11)
            page.textColor = .secondaryLabelColor
            page.lineBreakMode = .byTruncatingMiddle
            page.toolTip = context.url
            column.insertArrangedSubview(page, at: 2)
        }
        let instruction = session.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            let label = NSTextField(wrappingLabelWithString: "Instruction: \(instruction)")
            label.font = NSFont.systemFont(ofSize: 12)
            label.maximumNumberOfLines = 3
            column.addArrangedSubview(label)
        }

        // Actions.
        let view = actionButton("View", symbol: "photo", action: #selector(viewScreens(_:)), dir: summary.directory)
        view.isEnabled = !screens.isEmpty
        let copy = actionButton("Copy Prompt", symbol: "doc.on.clipboard", action: #selector(copyPrompt(_:)), dir: summary.directory)
        copy.isEnabled = summary.isFinished
        let reveal = actionButton("Reveal", symbol: "folder", action: #selector(reveal(_:)), dir: summary.directory)
        let delete = actionButton("Delete", symbol: "trash", action: #selector(deleteSession(_:)), dir: summary.directory)
        delete.hasDestructiveAction = true
        delete.isEnabled = !summary.isOpen
        var buttons: [NSView] = [view, copy]
        if summary.hasFeedback {
            buttons.append(actionButton("Copy Feedback", symbol: "text.badge.checkmark",
                                        action: #selector(copyFeedback(_:)), dir: summary.directory))
        }
        buttons.append(contentsOf: [reveal, delete])
        let actions = NSStackView(views: buttons)
        actions.orientation = .horizontal
        actions.spacing = 6

        let idLabel = NSTextField(labelWithString: session.id)
        idLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        idLabel.textColor = .tertiaryLabelColor
        let actionColumn = NSStackView(views: [actions, idLabel])
        actionColumn.orientation = .vertical
        actionColumn.alignment = .trailing
        actionColumn.spacing = 6

        let row = NSStackView(views: [thumbs, column, actionColumn])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionColumn.setContentHuggingPriority(.required, for: .horizontal)
        thumbs.setContentHuggingPriority(.required, for: .horizontal)

        box.contentView?.addSubview(row)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                row.topAnchor.constraint(equalTo: content.topAnchor),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        return box
    }

    private func actionButton(_ title: String, symbol: String, action: Selector, dir: URL) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageLeading
        button.font = NSFont.systemFont(ofSize: 11)
        button.identifier = NSUserInterfaceItemIdentifier(dir.path)
        return button
    }

    private func loadThumbnail(_ url: URL, into view: ThumbnailView) {
        thumbnailQueue.async {
            let image = Renderer.thumbnail(of: url, maxPixelSize: 480)
            DispatchQueue.main.async {
                guard let image else { return }
                view.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    // MARK: - Actions

    private func directory(for sender: Any?) -> URL? {
        (sender as? NSButton)?.identifier.map { URL(fileURLWithPath: $0.rawValue) }
    }

    @objc private func copyPrompt(_ sender: Any?) {
        guard let dir = directory(for: sender) else { return }
        onCopyPrompt?(dir)
    }

    /// Open the full-size viewer on one session, starting at a given screen.
    private func openViewer(for summary: SessionStore.Summary, startAt index: Int) {
        let items = summary.session.orderedScreens.map { screen in
            ScreenshotViewerController.Item(
                index: screen.index,
                annotated: summary.directory.appendingPathComponent("screen-\(screen.index)-annotated.png"),
                raw: summary.directory.appendingPathComponent("screen-\(screen.index).png"),
                subtitle: Self.subtitle(for: screen, in: summary.session)
            )
        }
        let title = "\(summary.session.id)  ·  \(summary.session.markCount) mark\(summary.session.markCount == 1 ? "" : "s")"
        guard let viewer = ScreenshotViewerController(sessionTitle: title, items: items, startAt: index) else { return }
        self.viewer = viewer
        viewer.present()
    }

    /// The notes on this screen, or the page it was captured on when there are none.
    private static func subtitle(for screen: Screen, in session: Session) -> String {
        let offset = session.numberOffset(forScreenIndex: screen.index)
        let notes = screen.orderedMarks.enumerated().compactMap { i, mark -> String? in
            let note = mark.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return note.isEmpty ? nil : "[\(offset + i + 1)] \(note)"
        }
        if !notes.isEmpty { return notes.joined(separator: "   ·   ") }
        if let context = screen.context { return context.shortURL }
        return screen.marks.isEmpty ? "No marks" : "\(screen.marks.count) mark(s), no notes"
    }

    /// Debug hook entry point: open the viewer on the newest session that has screens.
    func openNewestSession() {
        guard let summary = store.allSessions().first(where: { !$0.session.screens.isEmpty }),
              let first = summary.session.orderedScreens.first else { return }
        openViewer(for: summary, startAt: first.index)
    }

    @objc private func viewScreens(_ sender: Any?) {
        guard let dir = directory(for: sender),
              let summary = store.allSessions().first(where: { $0.directory.standardizedFileURL == dir.standardizedFileURL }),
              let first = summary.session.orderedScreens.first else { return }
        openViewer(for: summary, startAt: first.index)
    }

    @objc private func copyFeedback(_ sender: Any?) {
        guard let dir = directory(for: sender) else { return }
        onCopyFeedback?(dir)
    }

    @objc private func reveal(_ sender: Any?) {
        guard let dir = directory(for: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func deleteSession(_ sender: Any?) {
        guard let dir = directory(for: sender), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete session \(dir.lastPathComponent)?"
        alert.informativeText = "Its screenshots, crops, and prompt will be moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: dir, resultingItemURL: &trashed)) == nil {
                store.delete(sessionAt: dir)
            }
            reload()
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(store.sessionsDir)
    }
}

/// Thumbnail that reports a click; the hub decides what to open.
private final class ThumbnailView: NSImageView {
    private let onClick: () -> Void

    init(size: NSSize, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(origin: .zero, size: size))
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
