import AppKit
import Sparkle

/// Sparkle auto-updates, kept deliberately quiet.
///
/// The app is distributed to friends and teammates as a notarized `.app`, not through the
/// App Store, so it has to update itself. Sparkle checks an appcast (`SUFeedURL`) and will
/// only install a build whose EdDSA signature matches `SUPublicEDKey` — that key is what
/// stops a hijacked feed from shipping arbitrary code, so a build without one refuses to
/// update at all rather than updating unsafely.
final class Updater: NSObject, SPUUpdaterDelegate {
    /// nil in a build that cannot update itself; see `isConfigured`.
    private let controller: SPUStandardUpdaterController?

    /// True when this build knows where the appcast lives *and* which key signs it.
    ///
    /// Both come from `Resources/Info.plist`. Until `Scripts/release.sh` reports a public key
    /// to paste in there, `SUPublicEDKey` is empty and every build — dev and release alike —
    /// is unconfigured: no Updates menu item, no background checks, no error dialogs.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = (info?["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info?["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return !feed.isEmpty && !key.isEmpty
    }

    override init() {
        if Updater.isConfigured {
            // startingUpdater: true schedules the background check itself. Sparkle asks on
            // second launch whether automatic checks are OK, so we don't prompt separately.
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        } else {
            controller = nil
        }
        super.init()
        if let updater = controller?.updater {
            Log.info("updater: feed \(updater.feedURL?.absoluteString ?? "none"), automatic checks \(updater.automaticallyChecksForUpdates)")
        } else {
            Log.info("updater: not configured (no SUFeedURL/SUPublicEDKey) — updates disabled")
        }
    }

    /// Shows Sparkle's own progress and release-notes UI. No-op when unconfigured, but the
    /// menu item is hidden in that case so it should not be reachable.
    func checkForUpdates() {
        guard let controller else {
            Log.info("updater: check requested but updates are disabled in this build")
            return
        }
        // Sparkle's window is ordinary app UI; an LSUIElement app has to activate to show it.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
