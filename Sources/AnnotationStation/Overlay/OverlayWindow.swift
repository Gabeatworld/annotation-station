import AppKit

/// Full-screen borderless window over one display: the frozen capture underneath,
/// the `OverlayView` (marks + input) on top. See PLAN.md §7 for the key-window gotchas.
final class OverlayWindow: NSWindow {
    let targetScreen: NSScreen
    let overlayView = OverlayView()
    private let backdrop = BackdropView()

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        overlayView.frame = content.bounds
        overlayView.autoresizingMask = [.width, .height]
        content.addSubview(backdrop)
        content.addSubview(overlayView)
        contentView = content
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func setImage(_ image: CGImage) {
        backdrop.image = image
    }

    /// Activate us and take keyboard focus (borderless windows don't by default).
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(overlayView)
    }
}

/// Layer-backed view that just shows the capture; drawing marks lives in `OverlayView`.
private final class BackdropView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resize
        layer.contents = image
    }
}
