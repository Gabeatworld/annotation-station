import AppKit

enum Clipboard {
    /// Text-only pasteboard (PLAN.md §4/§8). A second image item would make some targets
    /// paste the image and drop the text.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
