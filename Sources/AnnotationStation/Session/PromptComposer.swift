import Foundation

/// `render(session) -> String`: the text that lands on the clipboard and in `prompt.md`.
/// Pure so a template setting can replace it later (PLAN.md §4).
enum PromptComposer {
    static let header = """
    Annotated screenshots follow. Each screen is an image with numbered marks; [n] refers to a mark.
    Boxes mark a region. Arrows point from a thing to where it should go or what it should relate to.
    Read every image before answering.
    """

    static func rawPath(screenIndex: Int, in directory: URL) -> String {
        directory.appendingPathComponent("screen-\(screenIndex).png").path
    }

    static func annotatedPath(screenIndex: Int, in directory: URL) -> String {
        directory.appendingPathComponent("screen-\(screenIndex)-annotated.png").path
    }

    static func regionPath(number: Int, in directory: URL) -> String {
        directory.appendingPathComponent("region-\(number).png").path
    }

    static func render(session: Session, directory: URL) -> String {
        var lines: [String] = [header, ""]
        var number = 0
        for screen in session.orderedScreens {
            lines.append("## Screen \(screen.index) — \(annotatedPath(screenIndex: screen.index, in: directory))")
            for mark in screen.marks.sorted(by: { $0.seq < $1.seq }) {
                number += 1
                var line = "- [\(number)]"
                if mark.kind.isArrow { line += " (arrow)" }
                let note = mark.note
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty { line += " " + note }
                if MarkGeometry.cropIsUseful(mark.kind, screenSize: screen.pointSize) {
                    line += "   (crop: \(regionPath(number: number, in: directory)))"
                }
                lines.append(line)
            }
            lines.append("")
        }
        let instruction = session.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            lines.append("## Instruction")
            lines.append(instruction)
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }
}
