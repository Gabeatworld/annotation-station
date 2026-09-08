import XCTest
@testable import AnnotationStation

final class GeometryTests: XCTestCase {
    // MARK: Creating

    func testRectFromDragIsNormalized() {
        let r = MarkGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 40, y: 130), square: false)
        XCTAssertEqual(r, CGRect(x: 40, y: 100, width: 60, height: 30))
    }

    func testShiftConstrainsToSquareKeepingDirection() {
        let r = MarkGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 40, y: 130), square: true)
        XCTAssertEqual(r, CGRect(x: 40, y: 100, width: 60, height: 60))
    }

    func testArrowSnapsTo45Degrees() {
        let head = MarkGeometry.snappedToAngle(from: .zero, to: CGPoint(x: 100, y: 10))
        XCTAssertEqual(head.x, 100.5, accuracy: 0.01)
        XCTAssertEqual(head.y, 0, accuracy: 0.01)
        let diag = MarkGeometry.snappedToAngle(from: .zero, to: CGPoint(x: 90, y: 100))
        XCTAssertEqual(diag.x, diag.y, accuracy: 0.01)
    }

    func testTinyDragsAreDegenerate() {
        XCTAssertTrue(MarkGeometry.isDegenerate(.box(CGRect(x: 0, y: 0, width: 3, height: 30))))
        XCTAssertTrue(MarkGeometry.isDegenerate(.arrow(from: .zero, to: CGPoint(x: 2, y: 2))))
        XCTAssertFalse(MarkGeometry.isDegenerate(.box(CGRect(x: 0, y: 0, width: 4, height: 4))))
    }

    // MARK: Hit-testing

    func testArrowHitWithinSixPoints() {
        let kind = Mark.Kind.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertTrue(MarkGeometry.hits(kind, CGPoint(x: 50, y: 6)))
        XCTAssertFalse(MarkGeometry.hits(kind, CGPoint(x: 50, y: 6.5)))
        XCTAssertFalse(MarkGeometry.hits(kind, CGPoint(x: 110, y: 0)))   // beyond the head
        XCTAssertEqual(MarkGeometry.distance(from: CGPoint(x: -3, y: 4), toSegment: .zero, CGPoint(x: 100, y: 0)), 5)
    }

    func testEndpointsBeatBody() {
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 110, y: 10)
        XCTAssertEqual(MarkGeometry.arrowEnd(from: a, to: b, near: CGPoint(x: 105, y: 14)), .head)
        XCTAssertEqual(MarkGeometry.arrowEnd(from: a, to: b, near: CGPoint(x: 14, y: 6)), .tail)
        XCTAssertNil(MarkGeometry.arrowEnd(from: a, to: b, near: CGPoint(x: 60, y: 10)))
    }

    func testBoxCornerAndBody() {
        let r = CGRect(x: 100, y: 100, width: 50, height: 50)
        XCTAssertEqual(MarkGeometry.corner(of: r, near: CGPoint(x: 152, y: 148)), .bottomRight)
        XCTAssertEqual(MarkGeometry.Corner.bottomRight.opposite, .topLeft)
        XCTAssertTrue(MarkGeometry.hits(.box(r), CGPoint(x: 125, y: 125)))
        XCTAssertTrue(MarkGeometry.hits(.box(r), CGPoint(x: 95, y: 125)))    // 5pt outside the edge
        XCTAssertFalse(MarkGeometry.hits(.box(r), CGPoint(x: 90, y: 125)))
    }

    func testArrowHeadStopsShaftShortOfTip() {
        let head = MarkGeometry.arrowHead(from: .zero, to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(head.tip, CGPoint(x: 100, y: 0))
        XCTAssertEqual(head.shaftEnd.x, 100 - MarkGeometry.headLength, accuracy: 0.001)
        XCTAssertEqual(head.left.y, MarkGeometry.headWidth / 2, accuracy: 0.001)
        XCTAssertEqual(head.right.y, -MarkGeometry.headWidth / 2, accuracy: 0.001)
    }

    // MARK: Crops (points → pixels, padding, clamping)

    func testCropRectScalesPadsAndClamps() {
        // Boxes larger than minCropSize so only scale + padding apply.
        let px = CGSize(width: 1000, height: 800)
        let big = MarkGeometry.cropRect(for: .box(CGRect(x: 10, y: 10, width: 200, height: 180)), scale: 2, pixelSize: px)
        XCTAssertEqual(big, CGRect(x: 12, y: 12, width: 416, height: 376))

        let edge = MarkGeometry.cropRect(for: .box(CGRect(x: 0, y: 0, width: 200, height: 180)), scale: 2, pixelSize: px)
        XCTAssertEqual(edge.origin, .zero)
        XCTAssertEqual(edge.size, CGSize(width: 408, height: 368))

        let overflow = MarkGeometry.cropRect(for: .box(CGRect(x: 350, y: 230, width: 200, height: 180)), scale: 2, pixelSize: px)
        XCTAssertEqual(overflow.maxX, 1000)
        XCTAssertEqual(overflow.maxY, 800)
    }

    func testSmallBoxCropGrowsToMinimumAroundItsCenter() {
        let r = MarkGeometry.cropRect(for: .box(CGRect(x: 400, y: 300, width: 20, height: 10)), scale: 1, pixelSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(r.width, MarkGeometry.minCropSize + 2 * MarkGeometry.cropPadding)
        XCTAssertEqual(r.height, MarkGeometry.minCropSize + 2 * MarkGeometry.cropPadding)
        XCTAssertEqual(r.midX, 410, accuracy: 0.5)
        XCTAssertEqual(r.midY, 305, accuracy: 0.5)
    }

    func testThinArrowCropGetsMinimumContext() {
        let r = MarkGeometry.cropRect(for: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100)), scale: 1, pixelSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(r.height, MarkGeometry.minCropSize + 2 * MarkGeometry.cropPadding)
        XCTAssertEqual(r.midY, 100, accuracy: 0.5)
    }

    func testCropUsefulnessThreshold() {
        let screen = CGSize(width: 1000, height: 1000)
        XCTAssertTrue(MarkGeometry.cropIsUseful(.box(CGRect(x: 0, y: 0, width: 600, height: 1000)), screenSize: screen))
        XCTAssertFalse(MarkGeometry.cropIsUseful(.box(CGRect(x: 0, y: 0, width: 800, height: 800)), screenSize: screen))
    }

    // MARK: Numbering across screens

    private func session() -> Session {
        let s1 = Screen(index: 1, displayID: 1, scale: 2, pointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200),
                        marks: [Mark(seq: 1, kind: .box(.zero), note: "a"), Mark(seq: 2, kind: .box(.zero), note: "b")], capturedAt: Date())
        let s2 = Screen(index: 2, displayID: 1, scale: 2, pointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 200, height: 200),
                        marks: [Mark(seq: 1, kind: .arrow(from: .zero, to: .zero), note: "c")], capturedAt: Date())
        return Session(id: "t", screens: [s2, s1])
    }

    func testNumbersAreDenseAndOrderedByScreenThenSeq() {
        let s = session()
        XCTAssertEqual(s.numberedMarks.map(\.number), [1, 2, 3])
        XCTAssertEqual(s.numberedMarks.map(\.mark.note), ["a", "b", "c"])
        XCTAssertEqual(s.numberOffset(forScreenIndex: 2), 2)
        XCTAssertEqual(s.numberOffset(forScreenIndex: 1), 0)
    }

    func testDeletingRenumbersAcrossScreens() {
        var s = session()
        let i = s.screens.firstIndex { $0.index == 1 }!
        s.screens[i].marks.removeFirst()   // delete [1]
        XCTAssertEqual(s.numberedMarks.map(\.number), [1, 2])
        XCTAssertEqual(s.numberedMarks.map(\.mark.note), ["b", "c"])
        XCTAssertEqual(s.numberOffset(forScreenIndex: 2), 1)
    }

    func testBadgeStaysInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 500)
        let c = MarkGeometry.badgeCenter(for: .box(CGRect(x: 0, y: 0, width: 50, height: 50)), in: bounds)
        XCTAssertGreaterThanOrEqual(c.x, MarkGeometry.badgeDiameter / 2)
        XCTAssertGreaterThanOrEqual(c.y, MarkGeometry.badgeDiameter / 2)
        let arrow = MarkGeometry.badgeCenter(for: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 100)), in: bounds)
        XCTAssertLessThan(arrow.x, 100)   // behind the tail
        XCTAssertEqual(arrow.y, 100)
    }
}
