import XCTest
import CoreGraphics
@testable import AnnotationStation

final class RendererTests: XCTestCase {
    /// A solid image stands in for a capture; the frame's geometry is what is under test.
    private func image(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testFramedAddsMarginsAndChrome() throws {
        let shot = image(width: 800, height: 500)
        let framed = try Renderer.framed(shot, title: "Proper — dev.client.proper.ai/health-check",
                                         detail: "Google Chrome 152 · display 1728 × 1117 pt @2x",
                                         notes: [], scale: 2)
        // A margin either side, and the title bar plus caption line stacked vertically.
        XCTAssertEqual(framed.width, 800 + Int(Renderer.Frame.margin * 2 * 2))
        XCTAssertGreaterThan(framed.height, 500 + Int(Renderer.Frame.margin * 2 * 2 + Renderer.Frame.titleBar * 2))
    }

    /// A capture with no page context still frames; the title bar is simply empty.
    func testFramedWithoutTitle() throws {
        let framed = try Renderer.framed(image(width: 400, height: 300), title: nil, detail: "display 1440 × 900 pt @1x", notes: [], scale: 1)
        XCTAssertEqual(framed.width, 400 + Int(Renderer.Frame.margin * 2))
    }

    /// The legend is what makes a pasted image self-contained, so it has to take real space.
    func testNotesLegendGrowsTheCanvas() throws {
        let shot = image(width: 600, height: 400)
        let bare = try Renderer.framed(shot, title: nil, detail: "display 1440 × 900 pt @1x", notes: [], scale: 1)
        let annotated = try Renderer.framed(shot, title: nil, detail: "display 1440 × 900 pt @1x", notes: [
            Renderer.Note(number: 1, text: "Card grid is misaligned with the header", isArrow: false),
            Renderer.Note(number: 2, text: "", isArrow: true),
        ], scale: 1)
        XCTAssertEqual(annotated.width, bare.width)
        XCTAssertGreaterThan(annotated.height, bare.height)
    }

    /// A note long enough to wrap must not be clipped to one line.
    func testLongNoteWraps() throws {
        let shot = image(width: 600, height: 400)
        let short = try Renderer.framed(shot, title: nil, detail: "d", notes: [
            Renderer.Note(number: 1, text: "Short", isArrow: false),
        ], scale: 1)
        let long = try Renderer.framed(shot, title: nil, detail: "d", notes: [
            Renderer.Note(number: 1, text: String(repeating: "This note is long enough to wrap several times. ", count: 6), isArrow: false),
        ], scale: 1)
        XCTAssertGreaterThan(long.height, short.height)
    }

    func testBadgeSizeGrowsWithDigits() {
        XCTAssertEqual(Renderer.badgeSize(for: 1).width, MarkGeometry.badgeDiameter)
        XCTAssertGreaterThan(Renderer.badgeSize(for: 100).width, MarkGeometry.badgeDiameter)
    }
}
