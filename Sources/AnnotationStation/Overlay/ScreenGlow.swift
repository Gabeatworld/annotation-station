import AppKit
import QuartzCore

/// Siri-style breathing glow hugging the edge of the display the overlay froze, so on a
/// multi-monitor desk it is obvious at a glance which screen you are marking up.
///
/// Both halves are baked into images once per screen size — a colour sweep and an edge-falloff
/// mask — so the only things that run per frame are a layer rotation and an opacity pulse, both
/// of which Core Animation does on the GPU without redrawing anything. Purely decorative: it
/// never takes a click, and it is not burned into the annotated PNG.
final class ScreenGlowView: NSView {
    /// How far the light reaches in from the screen edge, in points.
    private static let thickness: CGFloat = 26
    /// Roughly the corner of a modern Mac display; on a square external panel it still reads fine.
    private static let cornerRadius: CGFloat = 24
    /// Longest edge of the rasterised mask. A soft falloff carries no high-frequency detail, so
    /// drawing it at retina size would just burn milliseconds on the path that has to stay fast.
    private static let maskLongEdge: CGFloat = 900
    /// Side of the pre-rendered colour wheel.
    private static let sweepSide = 1024

    /// Warm-anchored sweep: the mark red the app already uses, carried around through orange,
    /// pink and violet so the travel is visible without turning into a rainbow.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // mark red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),   // orange
        NSColor(srgbRed: 1.00, green: 0.18, blue: 0.53, alpha: 1),   // pink
        NSColor(srgbRed: 0.58, green: 0.31, blue: 0.95, alpha: 1),   // violet
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // back to red, seamless
    ]

    private let sweep = CALayer()
    private let edgeMask = CALayer()
    private var maskedSize: CGSize = .zero

    /// The colour wheel never changes, so every overlay shares one.
    private static let sweepImage: CGImage? = conicSweep()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        sweep.contents = Self.sweepImage
        sweep.contentsGravity = .resize
        layer?.addSublayer(sweep)

        edgeMask.contentsGravity = .resize
        layer?.mask = edgeMask
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Decoration only: clicks, drags and the crosshair all belong to the OverlayView underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // The sweep rotates, so it has to be square and wide enough that its corners still
        // cover the screen at every angle.
        let diagonal = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
        sweep.position = CGPoint(x: bounds.midX, y: bounds.midY)
        edgeMask.frame = bounds
        CATransaction.commit()

        if bounds.size != maskedSize {
            maskedSize = bounds.size
            if let falloff = Self.edgeFalloff(size: bounds.size) { edgeMask.contents = falloff }
        }
    }

    // MARK: - Animation

    func start() {
        layer?.removeAllAnimations()
        sweep.removeAllAnimations()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.opacity = 0.44
            return
        }

        // Breathing: slow, shallow, and never all the way out — the screen should look alive,
        // not like something is flashing at you.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.32
        breathe.toValue = 0.74
        breathe.duration = 2.7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.opacity = 0.52
        layer?.add(breathe, forKey: "breathe")

        // The colour travels around the border; one lap is slow enough to read as ambient.
        let travel = CABasicAnimation(keyPath: "transform.rotation.z")
        travel.fromValue = 0
        travel.toValue = 2 * Double.pi
        travel.duration = 16
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.add(travel, forKey: "travel")
    }

    func stop() {
        layer?.removeAllAnimations()
        sweep.removeAllAnimations()
    }

    // MARK: - Baked images

    /// The colour wheel, drawn as wedges. Rendered once for the whole app; rotating the layer
    /// that shows it is what makes the colour travel.
    private static func conicSweep() -> CGImage? {
        let side = sweepSide
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let radius = CGFloat(side)          // overshoot so the wedges reach every corner
        let wedges = 360
        for i in 0..<wedges {
            // Overlap each wedge slightly so antialiasing never leaves a seam between them.
            let start = CGFloat(i) / CGFloat(wedges) * 2 * .pi
            let end = CGFloat(i + 1) / CGFloat(wedges) * 2 * .pi + 0.004
            ctx.setFillColor(color(at: CGFloat(i) / CGFloat(wedges)).cgColor)
            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    /// Linear interpolation through `palette`, with `t` in 0...1 around the wheel.
    private static func color(at t: CGFloat) -> NSColor {
        let span = 1 / CGFloat(palette.count - 1)
        let slot = min(palette.count - 2, Int(t / span))
        let local = (t - CGFloat(slot) * span) / span
        return palette[slot].blended(withFraction: local, of: palette[slot + 1]) ?? palette[slot]
    }

    /// A rounded-rect band that fades to nothing as it moves inward. Concentric strokes with a
    /// falling alpha give the same softness as a Gaussian blur for a fraction of the cost, and
    /// this runs once per screen size rather than once per frame.
    private static func edgeFalloff(size: CGSize) -> CGImage? {
        let scale = min(1, maskLongEdge / max(size.width, size.height))
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        let steps = 26
        for step in 0..<steps {
            let t = CGFloat(step) / CGFloat(steps - 1)          // 0 at the screen edge, 1 inward
            let inset = t * thickness
            // Quadratic falloff: bright right at the bezel, gone well before the content.
            let alpha = (1 - t) * (1 - t)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            guard rect.width > 0, rect.height > 0 else { break }
            let radius = max(2, cornerRadius - inset)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setStrokeColor(gray: 1, alpha: alpha)
            ctx.setLineWidth(thickness / CGFloat(steps) * 2.2)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
