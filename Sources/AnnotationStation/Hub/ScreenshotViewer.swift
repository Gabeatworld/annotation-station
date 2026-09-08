import AppKit

/// Full-size look at a session's screens without leaving the app. Arrow keys (or the buttons)
/// walk the screens, `O` flips between the annotated version and the untouched capture, and ⎋
/// closes. Preview and Finder are still one click away for anything this does not do.
final class ScreenshotViewerController: NSWindowController {
    struct Item {
        let index: Int
        let annotated: URL
        let raw: URL
        let subtitle: String

        /// Sessions that were never sent have no annotated PNG; fall back to the capture.
        var annotatedOrRaw: URL {
            FileManager.default.fileExists(atPath: annotated.path) ? annotated : raw
        }
    }

    private let items: [Item]
    private let sessionTitle: String
    private var position: Int
    private var showingOriginal = false

    private let imageView = NSImageView()
    private let counter = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let previous: NSButton
    private let next: NSButton
    private let originalToggle: NSButton

    init?(sessionTitle: String, items: [Item], startAt index: Int) {
        guard !items.isEmpty else { return nil }
        self.items = items
        self.sessionTitle = sessionTitle
        position = max(0, items.firstIndex { $0.index == index } ?? 0)
        previous = NSButton(title: "", target: nil, action: nil)
        next = NSButton(title: "", target: nil, action: nil)
        originalToggle = NSButton(checkboxWithTitle: "Show original  O", target: nil, action: nil)

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: visible.width * 0.7, height: visible.height * 0.78),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)
        window.contentView = KeyCatchingView()
        window.center()
        window.setFrameAutosaveName("ScreenshotViewer")
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window, let content = window.contentView else { return }
        (content as? KeyCatchingView)?.owner = self

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        // A capture's intrinsic size is the full pixel size of the display. Left alone, that
        // drags the window out past the screen edges — the view scales, so it needs no say.
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        imageView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        configure(previous, symbol: "chevron.left", tip: "Previous screen (←)", action: #selector(goPrevious))
        configure(next, symbol: "chevron.right", tip: "Next screen (→)", action: #selector(goNext))

        originalToggle.target = self
        originalToggle.action = #selector(toggleOriginal)
        originalToggle.controlSize = .small
        originalToggle.font = NSFont.systemFont(ofSize: 11)
        originalToggle.toolTip = "Hide the marks and show the untouched capture"

        counter.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let openInPreview = NSButton(title: "Open in Preview", target: self, action: #selector(openInPreview))
        openInPreview.bezelStyle = .rounded
        openInPreview.controlSize = .small
        openInPreview.font = NSFont.systemFont(ofSize: 11)
        let reveal = NSButton(title: "Reveal", target: self, action: #selector(reveal))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        reveal.font = NSFont.systemFont(ofSize: 11)

        let labels = NSStackView(views: [counter, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [previous, next, labels, NSView(), originalToggle, openInPreview, reveal])
        row.orientation = .horizontal
        row.spacing = 8
        row.setCustomSpacing(14, after: next)
        row.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addSubview(row)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(separator)

        content.addSubview(imageView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),
            separator.topAnchor.constraint(equalTo: bar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    // MARK: - State

    private var item: Item { items[position] }
    private var currentURL: URL { showingOriginal ? item.raw : item.annotatedOrRaw }

    private func refresh() {
        let url = currentURL
        imageView.image = NSImage(contentsOf: url)
        counter.stringValue = items.count == 1
            ? "Screen \(item.index)"
            : "Screen \(item.index)   ·   \(position + 1) of \(items.count)"
        subtitle.stringValue = item.subtitle
        subtitle.toolTip = item.subtitle
        previous.isEnabled = position > 0
        next.isEnabled = position < items.count - 1
        // Nothing to compare against on a session that was never sent.
        originalToggle.isEnabled = FileManager.default.fileExists(atPath: item.annotated.path)
        window?.title = sessionTitle
        window?.subtitle = showingOriginal ? "Original capture" : "Annotated"
    }

    @objc private func goPrevious() {
        guard position > 0 else { return }
        position -= 1
        refresh()
    }

    @objc private func goNext() {
        guard position < items.count - 1 else { return }
        position += 1
        refresh()
    }

    @objc private func toggleOriginal() {
        showingOriginal.toggle()
        originalToggle.state = showingOriginal ? .on : .off
        refresh()
    }

    @objc private func openInPreview() { NSWorkspace.shared.open(currentURL) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([currentURL]) }

    /// Called by the content view, which is what actually receives the key events.
    fileprivate func handle(key event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123, 126: goPrevious()          // ← / ↑
        case 124, 125: goNext()              // → / ↓
        case 53: close()                     // ⎋
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "o" else { return false }
            toggleOriginal()
        }
        return true
    }
}

/// The window's content view: borderless windows aside, an NSWindow only routes key events to
/// its first responder, and NSImageView will not become one.
final class KeyCatchingView: NSView {
    fileprivate weak var owner: ScreenshotViewerController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if owner?.handle(key: event) != true { super.keyDown(with: event) }
    }
}
