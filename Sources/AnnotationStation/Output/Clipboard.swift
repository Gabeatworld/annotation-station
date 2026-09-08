import AppKit

enum Clipboard {
    /// Text-only pasteboard (PLAN.md §4/§8). A second image item would make some targets
    /// paste the image and drop the text — which is exactly wrong for the agent path, where
    /// the text carries the absolute paths Claude Code needs.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Text plus the annotated PNGs as file items, for the website-feedback path. Slack, Linear
    /// and Notion attach the images and keep the text; a plain text field still gets the report.
    /// The text item goes first so anything that reads only the first item gets the report.
    static func copy(_ text: String, attaching files: [URL]) {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            copy(text)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString(text, forType: .string)
        var objects: [NSPasteboardWriting] = [textItem]
        objects.append(contentsOf: existing as [NSPasteboardWriting])
        pb.writeObjects(objects)
    }
}
