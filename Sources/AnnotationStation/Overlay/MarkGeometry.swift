import CoreGraphics
import Foundation

/// Pure geometry for marks: drag → shape, snapping, hit-testing, handles, badge placement, crops.
/// All inputs/outputs are in screen points with a top-left origin unless stated otherwise.
enum MarkGeometry {
    static let hitDistance: CGFloat = 6        // arrow line / box edge tolerance
    static let handleRadius: CGFloat = 8       // corner / endpoint grab radius
    static let minDragSize: CGFloat = 4        // smaller drags are ignored
    static let cropPadding: CGFloat = 8        // pixels added around a region crop
    static let minCropSize: CGFloat = 160      // points; tiny boxes and thin arrows get real context
    static let headLength: CGFloat = 14
    static let headWidth: CGFloat = 12
    static let badgeDiameter: CGFloat = 22
    static let cropUsefulFraction: CGFloat = 0.6

    // MARK: Creating

    static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x
        var dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Snap the head so the arrow angle is a multiple of 45°, keeping its length.
    static func snappedToAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
    }

    static func isDegenerate(_ kind: Mark.Kind) -> Bool {
        switch kind {
        case .box(let r): return r.width < minDragSize || r.height < minDragSize
        case .arrow(let a, let b): return distance(a, b) < minDragSize
        }
    }

    // MARK: Distances

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        var t: CGFloat = 0
        if len2 > 0 {
            t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
            t = min(1, max(0, t))
        }
        let proj = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return distance(p, proj)
    }

    // MARK: Arrow head

    struct ArrowHead {
        let tip: CGPoint
        let left: CGPoint
        let right: CGPoint
        /// Where the shaft stops so it doesn't poke through the tip.
        let shaftEnd: CGPoint
    }

    static func arrowHead(from a: CGPoint, to b: CGPoint) -> ArrowHead {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return ArrowHead(tip: b, left: b, right: b, shaftEnd: a) }
        let ux = dx / len, uy = dy / len
        let hl = min(headLength, len)
        let base = CGPoint(x: b.x - ux * hl, y: b.y - uy * hl)
        let px = -uy, py = ux
        let hw = headWidth / 2
        return ArrowHead(
            tip: b,
            left: CGPoint(x: base.x + px * hw, y: base.y + py * hw),
            right: CGPoint(x: base.x - px * hw, y: base.y - py * hw),
            shaftEnd: base
        )
    }

    // MARK: Hit-testing

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }

        var opposite: Corner {
            switch self {
            case .topLeft: return .bottomRight
            case .topRight: return .bottomLeft
            case .bottomLeft: return .topRight
            case .bottomRight: return .topLeft
            }
        }
    }

    enum ArrowEnd { case tail, head }

    static func corner(of rect: CGRect, near p: CGPoint) -> Corner? {
        Corner.allCases.first { distance($0.point(in: rect), p) <= handleRadius }
    }

    static func arrowEnd(from a: CGPoint, to b: CGPoint, near p: CGPoint) -> ArrowEnd? {
        if distance(b, p) <= handleRadius { return .head }
        if distance(a, p) <= handleRadius { return .tail }
        return nil
    }

    /// Body hit: inside/near a box's edge, or within `hitDistance` of an arrow's line.
    static func hits(_ kind: Mark.Kind, _ p: CGPoint) -> Bool {
        switch kind {
        case .box(let r):
            return r.insetBy(dx: -hitDistance, dy: -hitDistance).contains(p)
        case .arrow(let a, let b):
            return distance(from: p, toSegment: a, b) <= hitDistance
        }
    }

    // MARK: Badge

    /// Box: just outside the top-left corner. Arrow: behind the tail. Clamped to `bounds`.
    static func badgeCenter(for kind: Mark.Kind, in bounds: CGRect) -> CGPoint {
        let r = badgeDiameter / 2
        var c: CGPoint
        switch kind {
        case .box(let rect):
            c = CGPoint(x: rect.minX - r - 2, y: rect.minY - r - 2)
        case .arrow(let a, let b):
            let d = distance(a, b)
            if d > 0 {
                let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
                c = CGPoint(x: a.x - ux * (r + 4), y: a.y - uy * (r + 4))
            } else {
                c = a
            }
        }
        c.x = min(max(c.x, bounds.minX + r + 1), bounds.maxX - r - 1)
        c.y = min(max(c.y, bounds.minY + r + 1), bounds.maxY - r - 1)
        return c
    }

    // MARK: Crops

    /// Pixel rect for `region-n.png`: the mark's bounds grown to at least `minCropSize` points,
    /// converted to pixels, padded by `cropPadding` px, clamped to the image. Integral.
    static func cropRect(for kind: Mark.Kind, scale: CGFloat, pixelSize: CGSize) -> CGRect {
        var b = kind.bounds
        if b.width < minCropSize { b = b.insetBy(dx: -(minCropSize - b.width) / 2, dy: 0) }
        if b.height < minCropSize { b = b.insetBy(dx: 0, dy: -(minCropSize - b.height) / 2) }
        let px = CGRect(x: b.minX * scale, y: b.minY * scale, width: b.width * scale, height: b.height * scale)
            .insetBy(dx: -cropPadding, dy: -cropPadding)
        let image = CGRect(origin: .zero, size: pixelSize)
        let clamped = px.integral.intersection(image)
        return clamped.isNull ? .zero : clamped
    }

    /// A crop adds nothing when the mark already covers most of the screen (> 60% of its area).
    static func cropIsUseful(_ kind: Mark.Kind, screenSize: CGSize) -> Bool {
        let screenArea = screenSize.width * screenSize.height
        guard screenArea > 0 else { return false }
        let b = kind.bounds
        return (b.width * b.height) / screenArea <= cropUsefulFraction
    }
}
