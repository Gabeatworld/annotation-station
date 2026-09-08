import Foundation

/// Who filed the feedback and on what machine. Passed in rather than read inside the composer
/// so `render` stays pure and testable.
struct Reporter: Equatable {
    var fullName: String
    var accountName: String
    var osVersion: String

    static var current: Reporter {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Reporter(
            fullName: NSFullUserName(),
            accountName: NSUserName(),
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        )
    }

    /// "Gabriel Rimmerman (gabe)", or just the account name when they are the same.
    var display: String {
        let name = fullName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == accountName { return accountName }
        return "\(name) (\(accountName))"
    }
}

/// `feedback.md` for `CaptureMode.website`: the same marks as `prompt.md`, packaged for a
/// person instead of an agent. Image links are relative so the session folder can be zipped,
/// dropped in a ticket, or opened in any Markdown viewer and still render.
enum FeedbackComposer {
    static let fileName = "feedback.md"

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func render(session: Session, directory: URL, reporter: Reporter, timestamp: String? = nil) -> String {
        var lines: [String] = []
        let context = session.primaryContext

        lines.append("# Feedback — \(context?.shortURL ?? session.id)")
        lines.append("")
        lines.append("**Reported by** \(reporter.display)  ")
        lines.append("**When** \(timestamp ?? dateFormatter.string(from: session.createdAt))  ")
        lines.append("**System** \(reporter.osVersion)")
        lines.append("")

        var number = 0
        for screen in session.orderedScreens {
            lines.append("## Screen \(screen.index)\(screen.context.map { " — \($0.shortURL)" } ?? "")")
            lines.append("")
            lines.append(contentsOf: environment(for: screen))
            lines.append("![Screen \(screen.index)](screen-\(screen.index)-annotated.png)")
            lines.append("")
            for mark in screen.orderedMarks {
                number += 1
                var line = "- **[\(number)]**"
                if mark.kind.isArrow { line += " ↗" }
                let note = mark.note
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line += " " + (note.isEmpty ? "_no note_" : note)
                if MarkGeometry.cropIsUseful(mark.kind, screenSize: screen.pointSize) {
                    line += " ([crop](region-\(number).png))"
                }
                lines.append(line)
            }
            if screen.marks.isEmpty { lines.append("- _no marks on this screen_") }
            lines.append("")
        }

        let instruction = session.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            lines.append("## Notes")
            lines.append(instruction)
            lines.append("")
        }

        lines.append("---")
        lines.append("Full-size images: `\(directory.path)`")

        return lines.joined(separator: "\n") + "\n"
    }

    /// The environment block for one screen: what a developer needs to reproduce it.
    /// Everything except the display line is best effort, so each part is emitted only if known.
    private static func environment(for screen: Screen) -> [String] {
        var facts: [String] = []
        if let c = screen.context {
            let version = c.browserVersion.isEmpty ? c.browserName : "\(c.browserName) \(c.browserVersion)"
            facts.append(version)
            if let v = c.viewport {
                facts.append("viewport \(Int(v.width)) × \(Int(v.height)) CSS px")
            }
        }
        facts.append("display \(Int(screen.pointSize.width)) × \(Int(screen.pointSize.height)) pt @\(scaleLabel(screen.scale))")

        var lines = [facts.joined(separator: " · ")]
        if let c = screen.context {
            if !c.pageTitle.isEmpty { lines.append("Page title: \(c.pageTitle)") }
            lines.append("URL: <\(c.url)>")
        }
        // Two trailing spaces make each fact its own line in rendered Markdown.
        lines = lines.map { $0 + "  " }
        lines.append("")
        return lines
    }

    private static func scaleLabel(_ scale: CGFloat) -> String {
        scale == scale.rounded() ? "\(Int(scale))x" : String(format: "%.1fx", Double(scale))
    }
}
