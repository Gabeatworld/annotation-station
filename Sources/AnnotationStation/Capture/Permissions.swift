import ApplicationServices
import CoreGraphics

/// TCC permission helpers. Screen Recording is needed to capture the display (M0/M1);
/// Accessibility is needed only for auto-paste via synthetic ⌘V (M3).
///
/// Grants are keyed by bundle id + code signature, so always test with the ad-hoc-signed
/// `.app` produced by Scripts/bundle.sh, never the bare binary (PLAN.md §7).
enum Permissions {
    // MARK: Screen Recording

    /// True if Screen Recording is already granted. Does not prompt.
    static func hasScreenCapture() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system Screen Recording prompt the first time it is called for this
    /// bundle. Returns true if access is (already) granted. When the user grants access
    /// in System Settings after a denial, macOS requires the app to be relaunched.
    @discardableResult
    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Accessibility (used from M3)

    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
