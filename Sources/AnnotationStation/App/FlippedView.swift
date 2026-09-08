import AppKit

/// Plain container with a top-left origin, for laying things out top-down by frame.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
