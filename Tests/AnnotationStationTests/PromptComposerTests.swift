import XCTest
@testable import AnnotationStation

final class PromptComposerTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/Users/Gabe/.annotation-station/sessions/2026-09-07T16-30-12")

    private func screen(_ index: Int, marks: [Mark]) -> Screen {
        Screen(index: index, displayID: 1, scale: 2, pointSize: CGSize(width: 1000, height: 800),
               pixelSize: CGSize(width: 2000, height: 1600), marks: marks, capturedAt: Date())
    }

    func testTwoScreensWithArrowAndInstruction() {
        let s = Session(id: "2026-09-07T16-30-12", screens: [
            screen(1, marks: [
                Mark(seq: 1, kind: .box(CGRect(x: 10, y: 10, width: 200, height: 100)), note: "card grid is misaligned with the header"),
                Mark(seq: 2, kind: .box(CGRect(x: 0, y: 0, width: 900, height: 700)), note: "this should be the primary button"),
            ]),
            screen(2, marks: [
                Mark(seq: 1, kind: .box(CGRect(x: 10, y: 10, width: 50, height: 50)), note: "match the spacing of [1]"),
                Mark(seq: 2, kind: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300)), note: "move the filter chips up into the toolbar here"),
            ]),
        ], instruction: "  Fix the card grid so [1] lines up with the header.\n")

        let expected = """
        Annotated screenshots follow. Each screen is an image with numbered marks; [n] refers to a mark.
        Boxes mark a region. Arrows point from a thing to where it should go or what it should relate to.
        Read every image before answering.

        ## Screen 1 — \(dir.path)/screen-1-annotated.png
        - [1] card grid is misaligned with the header   (crop: \(dir.path)/region-1.png)
        - [2] this should be the primary button

        ## Screen 2 — \(dir.path)/screen-2-annotated.png
        - [3] match the spacing of [1]   (crop: \(dir.path)/region-3.png)
        - [4] (arrow) move the filter chips up into the toolbar here   (crop: \(dir.path)/region-4.png)

        ## Instruction
        Fix the card grid so [1] lines up with the header.

        """
        XCTAssertEqual(PromptComposer.render(session: s, directory: dir), expected)
    }

    func testEmptyInstructionAndEmptyNoteAreOmitted() {
        let s = Session(id: "x", screens: [
            screen(1, marks: [Mark(seq: 1, kind: .arrow(from: .zero, to: CGPoint(x: 100, y: 0)), note: "")]),
        ])
        let out = PromptComposer.render(session: s, directory: dir)
        XCTAssertFalse(out.contains("## Instruction"))
        XCTAssertTrue(out.contains("- [1] (arrow)   (crop: \(dir.path)/region-1.png)"))
        XCTAssertTrue(out.hasSuffix("region-1.png)\n"))
    }

    func testScreensAreOrderedByIndexAndNotesFlattened() {
        let s = Session(id: "x", screens: [
            screen(2, marks: [Mark(seq: 1, kind: .box(CGRect(x: 0, y: 0, width: 10, height: 10)), note: "two")]),
            screen(1, marks: [Mark(seq: 1, kind: .box(CGRect(x: 0, y: 0, width: 10, height: 10)), note: "one\nline two")]),
        ])
        let out = PromptComposer.render(session: s, directory: dir)
        XCTAssertTrue(out.contains("## Screen 1"))
        XCTAssertLessThan(out.range(of: "## Screen 1")!.lowerBound, out.range(of: "## Screen 2")!.lowerBound)
        XCTAssertTrue(out.contains("- [1] one line two"))
        XCTAssertTrue(out.contains("- [2] two"))
    }
}
