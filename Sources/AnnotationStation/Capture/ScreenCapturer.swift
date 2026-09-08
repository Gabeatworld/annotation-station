import AppKit
import ScreenCaptureKit

/// One frozen display.
struct Capture {
    let image: CGImage
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let scale: CGFloat
    let pointSize: CGSize
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// ScreenCaptureKit screenshot of the display under the cursor, at pixel (retina) size.
/// The shareable-content lookup is the slow part, so it is prefetched and cached.
/// Main-thread only (not actor-isolated so AppKit delegates can call it synchronously).

final class ScreenCapturer {
    enum CaptureError: LocalizedError {
        case noScreen
        case displayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .noScreen: return "No display found under the cursor."
            case .displayNotFound(let id): return "Display \(id) is not available for capture."
            }
        }
    }

    private var cached: SCShareableContent?
    private var prefetching = false

    static func screenUnderCursor() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    func prefetch() {
        guard !prefetching else { return }
        prefetching = true
        Task {
            defer { prefetching = false }
            do {
                cached = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                Log.error("prefetching shareable content: \(error.localizedDescription)")
            }
        }
    }

    func capture(screen: NSScreen) async throws -> Capture {
        let t0 = Date()
        let displayID = screen.displayID
        var content = cached
        var source = "cached"
        if content?.displays.first(where: { $0.displayID == displayID }) == nil {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            source = "fetched"
        }
        guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        let scale = screen.backingScaleFactor
        let pointSize = screen.frame.size
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.showsCursor = false
        config.scalesToFit = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        Log.info("captured display \(displayID): \(image.width)×\(image.height) px @\(scale)x in \(SessionStore.ms(since: t0)) ms (content \(source))")
        prefetch()
        return Capture(image: image, screen: screen, displayID: displayID, scale: scale, pointSize: pointSize)
    }
}
