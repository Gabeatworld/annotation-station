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
    /// How far the light reaches in from the screen edge, in points. Deliberately narrow: it
    /// only has to answer "which screen", and a wide band starts competing with the content.
    private static let thickness: CGFloat = 15
    /// Roughly the corner of a modern Mac display; on a square external panel it still reads fine.
    private static let cornerRadius: CGFloat = 24
    /// Longest edge of the rasterised mask. A soft falloff carries no high-frequency detail, so
    /// drawing it at retina size would just burn milliseconds on the path that has to stay fast.
    private static let maskLongEdge: CGFloat = 900
    /// Side of the pre-rendered colour wheel.
    private static let sweepSide = 1024

    /// Red, orange, pink, violet and blue, every stop kept pale.
    ///
    /// The wheel travels out along the warm-to-blue arc and back rather than making a full lap.
    /// A full lap has to cross the yellow-green arc somewhere, and a dark, unsaturated yellow is
    /// olive — which is exactly how it looked. Doubling back keeps every hue one worth showing,
    /// at the cost of opposite edges mirroring each other, which reads as symmetry rather than
    /// as repetition.
    ///
    /// First and last stop must stay identical or the sweep shows a seam where it wraps.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.961, green: 0.780, blue: 0.639, alpha: 1),  // orange
        NSColor(srgbRed: 0.949, green: 0.667, blue: 0.647, alpha: 1),  // red
        NSColor(srgbRed: 0.937, green: 0.729, blue: 0.855, alpha: 1),  // pink
        NSColor(srgbRed: 0.780, green: 0.663, blue: 0.914, alpha: 1),  // violet
        NSColor(srgbRed: 0.765, green: 0.765, blue: 0.937, alpha: 1),  // #C3C3EF, the mark accent
        NSColor(srgbRed: 0.608, green: 0.722, blue: 0.961, alpha: 1),  // periwinkle, the far end
        NSColor(srgbRed: 0.765, green: 0.765, blue: 0.937, alpha: 1),  // #C3C3EF
        NSColor(srgbRed: 0.780, green: 0.663, blue: 0.914, alpha: 1),  // violet
        NSColor(srgbRed: 0.937, green: 0.729, blue: 0.855, alpha: 1),  // pink
        NSColor(srgbRed: 0.949, green: 0.667, blue: 0.647, alpha: 1),  // red
        NSColor(srgbRed: 0.961, green: 0.780, blue: 0.639, alpha: 1),  // back to orange, seamless
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
            layer?.opacity = 0.32
            return
        }

        // Breathing: slow, shallow, and never all the way out — the screen should look alive,
        // not like something is flashing at you.
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.24
        breathe.toValue = 0.52
        breathe.duration = 3.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.opacity = 0.38
        layer?.add(breathe, forKey: "breathe")

        // The colour travels around the border. A lap takes the best part of a minute, so at any
        // given moment nothing appears to be moving — you only notice the edge is a different
        // colour than it was when you look back.
        let travel = CABasicAnimation(keyPath: "transform.rotation.z")
        travel.fromValue = 0
        travel.toValue = 2 * Double.pi
        travel.duration = 54
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

    /// Interpolation through `palette`, with `t` in 0...1 around the wheel.
    private static func color(at t: CGFloat) -> NSColor {
        let span = 1 / CGFloat(palette.count - 1)
        let slot = min(palette.count - 2, Int(t / span))
        let local = (t - CGFloat(slot) * span) / span
        return blend(palette[slot], palette[slot + 1], local)
    }

    /// Blend around the hue circle, not through RGB.
    ///
    /// Component-wise RGB blending between two stops far apart on the wheel passes through grey:
    /// mint to gold came out olive, and every other pair lost some life in the middle. Rotating
    /// the hue instead keeps each intermediate as clean as the stops on either side of it.
    private static func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        var ha: CGFloat = 0, sa: CGFloat = 0, ba: CGFloat = 0, aa: CGFloat = 0
        var hb: CGFloat = 0, sb: CGFloat = 0, bb: CGFloat = 0, ab: CGFloat = 0
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else { return a }
        ca.getHue(&ha, saturation: &sa, brightness: &ba, alpha: &aa)
        cb.getHue(&hb, saturation: &sb, brightness: &bb, alpha: &ab)
        // Take the short way round, so a pair either side of 0° does not run backwards
        // through every other hue.
        var delta = hb - ha
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        var hue = (ha + delta * t).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return NSColor(hue: hue,
                       saturation: sa + (sb - sa) * t,
                       brightness: ba + (bb - ba) * t,
                       alpha: aa + (ab - aa) * t)
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
