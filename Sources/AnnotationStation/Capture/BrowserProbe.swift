import AppKit

/// Reads the page behind the annotated screen: URL, title, and (when the browser allows it)
/// the CSS viewport. Feeds `CaptureMode.website`, where a human reviewer needs to know *where*
/// the marks were made, not just what they look like.
///
/// This talks to browsers over Apple events, so the first probe of each browser shows the
/// system "Annotation Station wants to control …" prompt. A denial is remembered by TCC, so
/// later captures fail fast (-1743) instead of prompting again. Everything runs off the main
/// thread: the overlay must never wait on a browser (PLAN.md: speed first).
enum BrowserProbe {
    /// Set `defaults write com.gabe.annotation-station websiteContext -bool false` to stop
    /// the app talking to browsers at all.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "websiteContext") as? Bool ?? true
    }

    enum Family {
        case safari
        case chromium
        /// Recognisably a browser, but it does not expose the front tab to AppleScript.
        case unscriptable
    }

    static let families: [String: Family] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "company.thebrowser.Browser": .chromium,   // Arc
        "com.sigmaos.sigmaos.macos": .chromium,
        "org.mozilla.firefox": .unscriptable,
        "org.mozilla.firefoxdeveloperedition": .unscriptable,
        "app.zen-browser.zen": .unscriptable,
    ]

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return families[id] != nil
    }

    private static let queue = DispatchQueue(label: "com.gabe.annotation-station.browser", qos: .userInitiated)

    /// `errAEEventNotPermitted`: TCC has a "no" on file for this browser.
    private static let notPermitted = -1743

    /// Asks `app` what it is showing. `completion` runs on the main thread, with nil whenever
    /// we cannot answer — the caller just leaves the screen without a context.
    static func context(for app: NSRunningApplication, completion: @escaping (PageContext?) -> Void) {
        guard isEnabled, let bundleID = app.bundleIdentifier, let family = families[bundleID] else {
            completion(nil)
            return
        }
        let name = app.localizedName ?? bundleID
        let version = version(of: app)
        guard family != .unscriptable else {
            Log.info("browser context: \(name) does not expose the front tab to AppleScript")
            completion(nil)
            return
        }
        queue.async {
            let t0 = Date()
            var context: PageContext?
            if let (url, title) = pageAndTitle(bundleID: bundleID, family: family) {
                context = PageContext(
                    browserName: name, browserVersion: version, bundleID: bundleID,
                    url: url, pageTitle: title,
                    viewport: viewport(bundleID: bundleID, family: family)
                )
                Log.info("browser context: \(name) \(version) — \(url) in \(SessionStore.ms(since: t0)) ms")
            }
            DispatchQueue.main.async { completion(context) }
        }
    }

    /// `CFBundleShortVersionString` off the running app — no Apple event, so it always works.
    static func version(of app: NSRunningApplication) -> String {
        guard let url = app.bundleURL, let bundle = Bundle(url: url) else { return "" }
        return bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - AppleScript

    /// Unit separator: joins the two return values without colliding with URL or title text.
    private static let separator = "\u{1F}"

    private static func pageAndTitle(bundleID: String, family: Family) -> (url: String, title: String)? {
        let source: String
        switch family {
        case .safari:
            source = """
            set d to character id 31
            tell application id "\(bundleID)"
                if (count of documents) is 0 then return ""
                return (URL of front document as text) & d & (name of front document as text)
            end tell
            """
        case .chromium:
            source = """
            set d to character id 31
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set t to active tab of front window
                return (URL of t as text) & d & (title of t as text)
            end tell
            """
        case .unscriptable:
            return nil
        }
        guard let raw = run(source, on: bundleID), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: separator)
        guard let url = parts.first, !url.isEmpty else { return nil }
        return (url, parts.count > 1 ? parts[1] : "")
    }

    /// Best effort: both families need "Allow JavaScript from Apple Events" turned on in their
    /// developer menu, which is off by default. A failure here is normal and not worth a warning.
    private static func viewport(bundleID: String, family: Family) -> CGSize? {
        let js = "window.innerWidth + 'x' + window.innerHeight"
        let source: String
        switch family {
        case .safari:
            source = """
            tell application id "\(bundleID)" to return (do JavaScript "\(js)" in front document) as text
            """
        case .chromium:
            source = """
            tell application id "\(bundleID)" to return (execute active tab of front window javascript "\(js)") as text
            """
        case .unscriptable:
            return nil
        }
        guard let raw = run(source, on: bundleID, quiet: true) else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// NSAppleScript is not thread-safe; every call comes in on `queue`.
    private static func run(_ source: String, on bundleID: String, quiet: Bool = false) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            guard !quiet else { return nil }
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            if code == notPermitted {
                Log.info("browser context: not allowed to control \(bundleID). Turn it on under System Settings › Privacy & Security › Automation › Annotation Station.")
            } else {
                Log.info("browser context: \(bundleID) returned \(code): \(message)")
            }
            return nil
        }
        return result.stringValue
    }
}
