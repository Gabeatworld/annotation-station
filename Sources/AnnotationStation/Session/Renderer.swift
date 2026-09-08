import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Mark styling: 3pt #C3C3EF stroke with a 1pt halo, 22pt badges.
///
/// The accent is pale, so the halo behind it is dark rather than white — a light stroke haloed
/// in white disappears against a light page, which is most of what gets annotated. Dark behind
/// light reads on both. Badge numerals are dark ink for the same reason.
enum MarkStyle {
    static let color = NSColor(srgbRed: 0xC3 / 255.0, green: 0xC3 / 255.0, blue: 0xEF / 255.0, alpha: 1)
    static let halo = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 0.85)
    /// Numerals and any text drawn on top of `color`.
    static let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1)
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

    /// The pill's size for a given number, so views that host a badge can lay one out.
    static func badgeSize(for number: Int) -> CGSize {
        let width = ("\(number)" as NSString).size(withAttributes: [.font: MarkStyle.badgeFont]).width
        return CGSize(width: max(MarkGeometry.badgeDiameter, width + 10), height: MarkGeometry.badgeDiameter)
    }

    static func drawBadge(_ number: Int, at center: CGPoint, in ctx: CGContext) {
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: MarkStyle.badgeFont, .foregroundColor: MarkStyle.ink]
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

        // Centre the digits optically, not by line box. A line box reserves room for a
        // descender that "1" or "4" never uses, so centring on it lifts the numeral off the
        // middle of the circle — visible at 22pt. Centre the cap height instead.
        let font = MarkStyle.badgeFont
        let baseline = rect.midY + font.capHeight / 2
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: baseline - font.ascender), withAttributes: attrs)
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


    // MARK: - Window mock (website feedback)

    /// Look of the framed screenshot website feedback ships as. Points; scaled to pixels at draw.
    enum Frame {
        static let margin: CGFloat = 44
        static let corner: CGFloat = 14
        static let titleBar: CGFloat = 40
        static let dotRadius: CGFloat = 6
        static let dotGap: CGFloat = 20
        static let captionGap: CGFloat = 16
        static let titleSize: CGFloat = 13
        static let detailSize: CGFloat = 12
        static let noteGap: CGFloat = 22
        static let noteRowGap: CGFloat = 11
        static let noteSize: CGFloat = 13
        /// Width reserved for the badge plus its gutter, so every note's text starts on one line.
        static let noteColumn: CGFloat = 36

        static let backdropTop = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.22, alpha: 1)
        static let backdropBottom = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
        static let chrome = NSColor(srgbRed: 0.15, green: 0.15, blue: 0.19, alpha: 1)
        static let chromeRule = NSColor(white: 1, alpha: 0.09)
        static let dot = NSColor(white: 1, alpha: 0.22)
        static let titleInk = NSColor(white: 1, alpha: 0.82)
        static let detailInk = NSColor(white: 1, alpha: 0.55)
        static let noteInk = NSColor(white: 1, alpha: 0.88)
        static let noteMutedInk = NSColor(white: 1, alpha: 0.4)
    }

    /// One numbered mark, for the legend printed under the framed capture.
    struct Note {
        let number: Int
        let text: String
        let isArrow: Bool
    }

    /// Frame a capture the way macOS frames a window screenshot: rounded corners, a drop shadow
    /// and a gradient backdrop, with the page in the title bar and the environment on a caption
    /// line underneath.
    ///
    /// The caption is the point, not decoration. Website feedback usually arrives as the image
    /// on its own — Slack, Linear and Notion take the pasted file off the pasteboard and drop
    /// the text that came with it — so the page, browser and display have to survive inside the
    /// picture or the reviewer sees marks with no idea what they were made on.
    static func framed(_ image: CGImage, title: String?, detail: String, notes: [Note], scale: CGFloat) throws -> CGImage {
        let s = max(scale, 1)
        let margin = Frame.margin * s
        let bar = Frame.titleBar * s
        let gap = Frame.captionGap * s

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Frame.titleSize * s, weight: .medium),
            .foregroundColor: Frame.titleInk,
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Frame.detailSize * s, weight: .regular),
            .foregroundColor: Frame.detailInk,
        ]
        let detailHeight = ceil((detail as NSString).size(withAttributes: detailAttrs).height)

        let cardW = CGFloat(image.width)
        let cardH = bar + CGFloat(image.height)
        let noteColumn = Frame.noteColumn * s
        let noteWidth = cardW - noteColumn
        let noteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Frame.noteSize * s, weight: .regular),
            .foregroundColor: Frame.noteInk,
        ]
        let mutedNoteAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Frame.noteSize * s, weight: .regular),
            .foregroundColor: Frame.noteMutedInk,
        ]
        // A long note wraps rather than truncating: it is the whole point of the picture.
        let badgeHeight = MarkGeometry.badgeDiameter * s
        let noteRows: [(note: Note, height: CGFloat, empty: Bool)] = notes.map { note in
            let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmed.isEmpty ? "—" : trimmed
            let bounds = (body as NSString).boundingRect(
                with: CGSize(width: noteWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: trimmed.isEmpty ? mutedNoteAttrs : noteAttrs)
            return (note, max(badgeHeight, ceil(bounds.height)), trimmed.isEmpty)
        }
        let notesHeight = noteRows.isEmpty ? 0
            : Frame.noteGap * s + noteRows.reduce(0) { $0 + $1.height } + Frame.noteRowGap * s * CGFloat(noteRows.count - 1)

        let w = Int((cardW + margin * 2).rounded())
        let h = Int((margin + cardH + notesHeight + gap + detailHeight + margin).rounded())

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.bitmapContext }

        // Everything below works in top-left points-as-pixels, like the rest of the renderer.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let full = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        if let gradient = CGGradient(colorsSpace: cs,
                                     colors: [Frame.backdropTop.cgColor, Frame.backdropBottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.addRect(full)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: full.maxY), options: [])
            ctx.restoreGState()
        }

        let card = CGRect(x: margin, y: margin, width: cardW, height: cardH)
        let cardPath = CGPath(roundedRect: card, cornerWidth: Frame.corner * s, cornerHeight: Frame.corner * s, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 44 * s,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(cardPath)
        ctx.setFillColor(Frame.chrome.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        // The capture fills the card below the title bar. ctx is flipped, so flip it back for
        // the image or it draws upside down.
        let shot = CGRect(x: card.minX, y: card.minY + bar, width: cardW, height: CGFloat(image.height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: shot.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: shot.minX, y: 0, width: shot.width, height: shot.height))
        ctx.restoreGState()

        ctx.setFillColor(Frame.chromeRule.cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.minY + bar - max(1, s), width: cardW, height: max(1, s)))

        var dotX = card.minX + 18 * s + Frame.dotRadius * s
        for _ in 0..<3 {
            let r = Frame.dotRadius * s
            ctx.setFillColor(Frame.dot.cgColor)
            ctx.fillEllipse(in: CGRect(x: dotX - r, y: card.minY + bar / 2 - r, width: r * 2, height: r * 2))
            dotX += Frame.dotGap * s
        }
        ctx.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        if let title, !title.isEmpty {
            // Centred in the title bar like a browser tab, inset past the dots on both sides so
            // a long URL truncates instead of running under them.
            let inset = dotX + 12 * s - card.minX
            let box = CGRect(x: card.minX + inset, y: card.minY,
                             width: max(0, cardW - inset * 2), height: bar)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            paragraph.alignment = .center
            var attrs = titleAttrs
            attrs[.paragraphStyle] = paragraph
            let lineHeight = (title as NSString).size(withAttributes: attrs).height
            (title as NSString).draw(in: CGRect(x: box.minX, y: box.midY - lineHeight / 2,
                                                width: box.width, height: lineHeight),
                                     withAttributes: attrs)
        }

        // The legend. Without it the reviewer gets numbered marks and nothing to read them
        // against, since the report they were numbered in does not survive the paste.
        var noteY = card.maxY + Frame.noteGap * s
        for row in noteRows {
            let badgeSize = Renderer.badgeSize(for: row.note.number)
            ctx.saveGState()
            ctx.translateBy(x: card.minX + badgeSize.width * s / 2, y: noteY + badgeHeight / 2)
            ctx.scaleBy(x: s, y: s)
            drawBadge(row.note.number, at: .zero, in: ctx)
            ctx.restoreGState()

            let body = row.empty ? "—" : row.note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = row.note.isArrow && !row.empty ? "↗  \(body)" : body
            (text as NSString).draw(with: CGRect(x: card.minX + noteColumn, y: noteY,
                                                 width: noteWidth, height: row.height),
                                    options: [.usesLineFragmentOrigin],
                                    attributes: row.empty ? mutedNoteAttrs : noteAttrs,
                                    context: nil)
            noteY += row.height + Frame.noteRowGap * s
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs = detailAttrs
        attrs[.paragraphStyle] = paragraph
        (detail as NSString).draw(in: CGRect(x: card.minX, y: card.maxY + notesHeight + gap, width: cardW, height: detailHeight),
                                  withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { throw RenderError.bitmapContext }
        return out
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
