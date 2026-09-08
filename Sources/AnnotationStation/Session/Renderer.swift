import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Mark styling from PLAN.md M1: 3pt #FF3B30 stroke with a 1pt white halo, 22pt badges.
enum MarkStyle {
    static let color = NSColor(srgbRed: 1.0, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1)
    static let halo = NSColor.white
    static let strokeWidth: CGFloat = 3
    static let haloWidth: CGFloat = 1
    static let badgeFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    static let dimAlpha: CGFloat = 0.2
}

enum RenderError: LocalizedError {
    case bitmapContext
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .bitmapContext: return "Could not create a bitmap context."
        case .cannotWrite(let url): return "Could not write \(url.lastPathComponent)."
        }
    }
}

/// Draws marks + badges. Used live by the overlay (points, 1:1) and by `annotatedImage`
/// (pixels, CTM scaled) so the two never drift apart.
enum Renderer {
    typealias Item = (kind: Mark.Kind, number: Int)

    /// `ctx` must be in top-left point coordinates and `NSGraphicsContext.current` must wrap it
    /// (flipped) so badge text renders upright.
    static func drawMarks(_ items: [Item], bounds: CGRect, dimOutsideBoxes: Bool, in ctx: CGContext) {
        if dimOutsideBoxes {
            let boxes: [CGRect] = items.compactMap {
                if case .box(let r) = $0.kind { return r }
                return nil
            }
            if !boxes.isEmpty {
                ctx.saveGState()
                ctx.setFillColor(NSColor.black.withAlphaComponent(MarkStyle.dimAlpha).cgColor)
                ctx.addRect(bounds)
                for r in boxes { ctx.addRect(r) }
                ctx.fillPath(using: .evenOdd)
                ctx.restoreGState()
            }
        }

        let haloWidth = MarkStyle.strokeWidth + 2 * MarkStyle.haloWidth
        for item in items {
            strokeMark(item.kind, color: MarkStyle.halo.cgColor, width: haloWidth, headOutline: 2 * MarkStyle.haloWidth, in: ctx)
        }
        for item in items {
            strokeMark(item.kind, color: MarkStyle.color.cgColor, width: MarkStyle.strokeWidth, headOutline: 0, in: ctx)
        }
        for item in items {
            drawBadge(item.number, at: MarkGeometry.badgeCenter(for: item.kind, in: bounds), in: ctx)
        }
    }

    private static func strokeMark(_ kind: Mark.Kind, color: CGColor, width: CGFloat, headOutline: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch kind {
        case .box(let r):
            ctx.stroke(r)
        case .arrow(let a, let b):
            let head = MarkGeometry.arrowHead(from: a, to: b)
            ctx.move(to: a)
            ctx.addLine(to: head.shaftEnd)
            ctx.strokePath()
            ctx.move(to: head.tip)
            ctx.addLine(to: head.left)
            ctx.addLine(to: head.right)
            ctx.closePath()
            if headOutline > 0 {
                ctx.setLineWidth(headOutline)
                ctx.drawPath(using: .fillStroke)
            } else {
                ctx.fillPath()
            }
        }
    }

    static func drawBadge(_ number: Int, at center: CGPoint, in ctx: CGContext) {
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: MarkStyle.badgeFont, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let d = MarkGeometry.badgeDiameter
        let w = max(d, size.width + 10)
        let rect = CGRect(x: center.x - w / 2, y: center.y - d / 2, width: w, height: d)

        ctx.saveGState()
        ctx.setFillColor(MarkStyle.halo.cgColor)
        let halo = rect.insetBy(dx: -MarkStyle.haloWidth, dy: -MarkStyle.haloWidth)
        ctx.addPath(CGPath(roundedRect: halo, cornerWidth: halo.height / 2, cornerHeight: halo.height / 2, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(MarkStyle.color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: d / 2, cornerHeight: d / 2, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    // MARK: - Burn-in

    /// The raw capture with this screen's marks and their (session-global) numbers burned in.
    static func annotatedImage(image: CGImage, screen: Screen, numbers: [Int]) throws -> CGImage {
        let w = image.width, h = image.height
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.bitmapContext }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Flip to a top-left origin and scale points → pixels. Line widths scale with the CTM.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / screen.pointSize.width, y: -CGFloat(h) / screen.pointSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let items = zip(screen.marks, numbers).map { Item(kind: $0.kind, number: $1) }
        drawMarks(items, bounds: CGRect(origin: .zero, size: screen.pointSize), dimOutsideBoxes: false, in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { throw RenderError.bitmapContext }
        return out
    }

    /// Full-resolution crop of a mark's region (see `MarkGeometry.cropRect`). Nil if empty.
    static func crop(image: CGImage, kind: Mark.Kind, scale: CGFloat) -> CGImage? {
        let rect = MarkGeometry.cropRect(for: kind, scale: scale, pixelSize: CGSize(width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    // MARK: - PNG I/O

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.cannotWrite(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.cannotWrite(url) }
    }

    /// Downscaled decode for hub thumbnails (never decodes the full-size bitmap).
    static func thumbnail(of url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func loadPNG(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
