import XCTest
@testable import AnnotationStation

final class FeedbackComposerTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/Users/Gabe/.annotation-station/sessions/2026-09-07T16-30-12")
    private let reporter = Reporter(fullName: "Gabriel Rimmerman", accountName: "gabe", osVersion: "macOS 15.6.1")

    private func screen(_ index: Int, marks: [Mark], context: PageContext? = nil) -> Screen {
        Screen(index: index, displayID: 1, scale: 2, pointSize: CGSize(width: 1000, height: 800),
               pixelSize: CGSize(width: 2000, height: 1600), marks: marks, capturedAt: Date(), context: context)
    }

    private let context = PageContext(
        browserName: "Google Chrome", browserVersion: "140.0.7339.81", bundleID: "com.google.Chrome",
        url: "https://example.com/pricing?plan=team", pageTitle: "Pricing — Example",
        viewport: CGSize(width: 1512, height: 823)
    )

    func testFullReport() {
        let s = Session(id: "2026-09-07T16-30-12", screens: [
            screen(1, marks: [
                Mark(seq: 1, kind: .box(CGRect(x: 10, y: 10, width: 200, height: 100)), note: "the card grid is misaligned with the header"),
                Mark(seq: 2, kind: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 300, y: 300)), note: "move the filter chips\ninto the toolbar"),
            ], context: context),
        ], instruction: "  Ship before the demo.\n", mode: .website)

        let expected = """
        # Feedback — example.com/pricing

        **Reported by** Gabriel Rimmerman (gabe)  
        **When** 7 Sep 2026 at 16:30  
        **System** macOS 15.6.1

        ## Screen 1 — example.com/pricing

        Google Chrome 140.0.7339.81 · viewport 1512 × 823 CSS px · display 1000 × 800 pt @2x  
        Page title: Pricing — Example  
        URL: <https://example.com/pricing?plan=team>  

        ![Screen 1](screen-1-annotated.png)

        - **[1]** the card grid is misaligned with the header ([crop](region-1.png))
        - **[2]** ↗ move the filter chips into the toolbar ([crop](region-2.png))

        ## Notes
        Ship before the demo.

        ---
        Full-size images: `\(dir.path)`

        """
        XCTAssertEqual(
            FeedbackComposer.render(session: s, directory: dir, reporter: reporter, timestamp: "7 Sep 2026 at 16:30"),
            expected
        )
    }

    func testWithoutBrowserContextTheDisplayIsStillReported() {
        let s = Session(id: "x", screens: [screen(1, marks: [Mark(seq: 1, kind: .box(CGRect(x: 0, y: 0, width: 900, height: 700)), note: "")])], mode: .website)
        let out = FeedbackComposer.render(session: s, directory: dir, reporter: reporter, timestamp: "now")
        XCTAssertTrue(out.hasPrefix("# Feedback — x\n"))
        XCTAssertTrue(out.contains("display 1000 × 800 pt @2x"))
        XCTAssertFalse(out.contains("URL:"))
        XCTAssertTrue(out.contains("- **[1]** _no note_"))
        // A box that covers most of the screen has no useful crop.
        XCTAssertFalse(out.contains("region-1.png"))
        XCTAssertFalse(out.contains("## Notes"))
    }

    func testNumbersRunAcrossScreensAndTitleUsesTheFirstPage() {
        let s = Session(id: "x", screens: [
            screen(2, marks: [Mark(seq: 1, kind: .box(CGRect(x: 0, y: 0, width: 20, height: 20)), note: "two")]),
            screen(1, marks: [Mark(seq: 1, kind: .box(CGRect(x: 0, y: 0, width: 20, height: 20)), note: "one")], context: context),
        ], mode: .website)
        let out = FeedbackComposer.render(session: s, directory: dir, reporter: reporter, timestamp: "now")
        XCTAssertTrue(out.hasPrefix("# Feedback — example.com/pricing\n"))
        XCTAssertLessThan(out.range(of: "## Screen 1")!.lowerBound, out.range(of: "## Screen 2")!.lowerBound)
        XCTAssertTrue(out.contains("- **[1]** one"))
        XCTAssertTrue(out.contains("- **[2]** two"))
    }

    func testShortURLStripsSchemeAndQuery() {
        XCTAssertEqual(context.shortURL, "example.com/pricing")
        var root = context
        root.url = "https://example.com/"
        XCTAssertEqual(root.shortURL, "example.com")
        var junk = context
        junk.url = "not a url"
        XCTAssertEqual(junk.shortURL, "not a url")
    }

    func testSessionJSONFromBeforeCaptureModesDecodesAsLLM() throws {
        let json = """
        {"createdAt":"2026-09-07T16:30:12Z","id":"old","instruction":"","screens":[]}
        """
        let s = try SessionStore.decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(s.mode, .llm)
        XCTAssertNil(s.primaryContext)
    }
}
