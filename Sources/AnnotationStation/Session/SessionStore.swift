import AppKit

enum StoreError: LocalizedError {
    case noSession
    case missingImage(Int)

    var errorDescription: String? {
        switch self {
        case .noSession: return "No session is open."
        case .missingImage(let i): return "The capture for screen \(i) is missing."
        }
    }
}

/// Owns the open session and its directory under `~/.annotation-station/sessions/<timestamp>/`.
/// `session.json` is rewritten on every mutation; PNG work runs on a serial background queue.
final class SessionStore {
    let rootDir: URL
    let sessionsDir: URL
    let currentLink: URL

    private(set) var session: Session?
    private(set) var sessionDir: URL?
    private var images: [Int: CGImage] = [:]
    private let ioQueue = DispatchQueue(label: "com.gabe.annotation-station.io", qos: .userInitiated)
    private let fm = FileManager.default

    init(rootDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".annotation-station")) {
        self.rootDir = rootDir
        sessionsDir = rootDir.appendingPathComponent("sessions")
        currentLink = rootDir.appendingPathComponent("current")
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    var isOpen: Bool { session != nil }

    /// "screens · marks" for the status item; empty when no session is open.
    var badge: String {
        guard let s = session else { return "" }
        return "\(s.screens.count) · \(s.markCount)"
    }

    // MARK: - Lifecycle

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    @discardableResult
    func beginSessionIfNeeded() throws -> Session {
        if let s = session { return s }
        let base = Self.idFormatter.string(from: Date())
        var id = base
        var dir = sessionsDir.appendingPathComponent(id)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            id = "\(base)-\(n)"
            dir = sessionsDir.appendingPathComponent(id)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = Session(id: id)
        session = s
        sessionDir = dir
        try save()
        setCurrentLink(dir)
        Log.info("session \(id) opened")
        return s
    }

    func addScreen(image: CGImage, displayID: UInt32, scale: CGFloat, pointSize: CGSize) throws -> Screen {
        guard var s = session, let dir = sessionDir else { throw StoreError.noSession }
        let index = (s.screens.map(\.index).max() ?? 0) + 1
        let screen = Screen(
            index: index, displayID: displayID, scale: scale, pointSize: pointSize,
            pixelSize: CGSize(width: image.width, height: image.height),
            marks: [], capturedAt: Date()
        )
        s.screens.append(screen)
        session = s
        images[index] = image
        try save()
        let raw = dir.appendingPathComponent("screen-\(index).png")
        ioQueue.async {
            let t0 = Date()
            do {
                try Renderer.writePNG(image, to: raw)
                Log.info("wrote \(raw.lastPathComponent) in \(Self.ms(since: t0)) ms")
            } catch {
                Log.error("writing \(raw.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return screen
    }

    func updateMarks(screenIndex: Int, marks: [Mark]) {
        guard var s = session, let i = s.screens.firstIndex(where: { $0.index == screenIndex }) else { return }
        s.screens[i].marks = marks
        session = s
        saveQuietly()
    }

    func setNote(markID: UUID, note: String) {
        guard var s = session else { return }
        for si in s.screens.indices {
            if let mi = s.screens[si].marks.firstIndex(where: { $0.id == markID }) {
                s.screens[si].marks[mi].note = note
            }
        }
        session = s
        saveQuietly()
    }

    func setInstruction(_ text: String) {
        guard var s = session else { return }
        s.instruction = text
        session = s
        saveQuietly()
    }

    func setMode(_ mode: CaptureMode) {
        guard var s = session, s.mode != mode else { return }
        s.mode = mode
        session = s
        saveQuietly()
    }

    /// Attaches the browser page a screen was captured on. Arrives late (the probe runs off the
    /// main thread) so the screen may already have marks, or be gone.
    func setContext(screenIndex: Int, context: PageContext) {
        guard var s = session, let i = s.screens.firstIndex(where: { $0.index == screenIndex }) else { return }
        s.screens[i].context = context
        session = s
        saveQuietly()
    }

    /// Drops a screen. If it was the last one, the whole session goes away.
    func removeScreen(index: Int) {
        guard var s = session, let dir = sessionDir else { return }
        s.screens.removeAll { $0.index == index }
        images[index] = nil
        let raw = dir.appendingPathComponent("screen-\(index).png")
        ioQueue.async { try? FileManager.default.removeItem(at: raw) }
        if s.screens.isEmpty {
            discardSession()
        } else {
            session = s
            saveQuietly()
            Log.info("screen \(index) removed; session keeps \(s.screens.count) screen(s)")
        }
    }

    func image(forScreen index: Int) -> CGImage? {
        if let img = images[index] { return img }
        guard let dir = sessionDir else { return nil }
        let img = Renderer.loadPNG(from: dir.appendingPathComponent("screen-\(index).png"))
        images[index] = img
        return img
    }

    /// What `finalize` produced: the document that belongs on the clipboard, and where it lives.
    struct Delivery {
        let mode: CaptureMode
        let text: String
        let directory: URL
        /// The annotated PNGs, in screen order — what a person actually wants pasted alongside
        /// the report.
        let images: [URL]
    }

    /// Burns marks into `screen-k-annotated.png`, crops `region-n.png`, writes `prompt.md` (and
    /// `feedback.md` in website mode), then closes the session (files stay). Rendering runs off
    /// the main thread; `completion` is called on the main thread.
    func finalize(completion: @escaping (Result<Delivery, Error>) -> Void) {
        guard let s = session, let dir = sessionDir else {
            completion(.failure(StoreError.noSession))
            return
        }
        var imgs = images
        for screen in s.screens where imgs[screen.index] == nil {
            imgs[screen.index] = Renderer.loadPNG(from: dir.appendingPathComponent("screen-\(screen.index).png"))
        }
        let t0 = Date()
        let reporter = Reporter.current
        ioQueue.async {
            do {
                var number = 0
                let stamp = FeedbackComposer.displayTimestamp(s.createdAt)
                for screen in s.orderedScreens {
                    guard let image = imgs[screen.index] else { throw StoreError.missingImage(screen.index) }
                    let marks = screen.orderedMarks
                    let numbers = (0..<marks.count).map { number + 1 + $0 }
                    var annotated = try Renderer.annotatedImage(image: image, screen: screen, numbers: numbers,
                                                                includeNotes: s.mode == .website)
                    // Website feedback gets the window treatment; the agent path keeps the bare
                    // capture, where a frame and a caption would only cost tokens.
                    if s.mode == .website {
                        let caption = FeedbackComposer.caption(for: screen, reporter: reporter, timestamp: stamp)
                        let legend = zip(marks, numbers).map {
                            Renderer.Note(number: $1, text: $0.note, isArrow: $0.kind.isArrow)
                        }
                        annotated = try Renderer.framed(annotated, title: caption.title,
                                                        detail: caption.detail, notes: legend,
                                                        scale: screen.scale)
                    }
                    try Renderer.writePNG(annotated, to: dir.appendingPathComponent("screen-\(screen.index)-annotated.png"))
                    for mark in marks {
                        number += 1
                        if let crop = Renderer.crop(image: image, kind: mark.kind, scale: screen.scale) {
                            try Renderer.writePNG(crop, to: dir.appendingPathComponent("region-\(number).png"))
                        }
                    }
                }
                // prompt.md is written for every mode: the hub's "Copy Prompt" and the recent
                // menu work the same whatever the session was sent as.
                let prompt = PromptComposer.render(session: s, directory: dir)
                try prompt.write(to: dir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
                var text = prompt
                if s.mode == .website {
                    let feedback = FeedbackComposer.render(session: s, directory: dir, reporter: reporter)
                    try feedback.write(to: dir.appendingPathComponent(FeedbackComposer.fileName), atomically: true, encoding: .utf8)
                    text = feedback
                }
                try Self.encoder.encode(s).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
                Log.info("finalized \(s.id) as \(s.mode.rawValue): \(s.screens.count) screen(s), \(number) mark(s) in \(Self.ms(since: t0)) ms")
                let images = s.orderedScreens.map { dir.appendingPathComponent("screen-\($0.index)-annotated.png") }
                let delivery = Delivery(mode: s.mode, text: text, directory: dir, images: images)
                DispatchQueue.main.async {
                    self.close()
                    completion(.success(delivery))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func discardSession() {
        if let dir = sessionDir {
            try? fm.removeItem(at: dir)
            Log.info("session \(dir.lastPathComponent) discarded")
        }
        close()
    }

    private func close() {
        session = nil
        sessionDir = nil
        images = [:]
        try? fm.removeItem(at: currentLink)
    }

    // MARK: - Persistence

    func save() throws {
        guard let s = session, let dir = sessionDir else { return }
        try Self.encoder.encode(s).write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    private func saveQuietly() {
        do { try save() } catch { Log.error("saving session.json: \(error.localizedDescription)") }
    }

    private func setCurrentLink(_ dir: URL) {
        try? fm.removeItem(at: currentLink)
        do {
            try fm.createSymbolicLink(at: currentLink, withDestinationURL: dir)
        } catch {
            Log.error("creating current symlink: \(error.localizedDescription)")
        }
    }

    // MARK: - Resume after crash

    /// The session `current` points to, if any (only exists while a session is open).
    func resumableSession() -> (session: Session, directory: URL)? {
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) else { return nil }
        let dir = URL(fileURLWithPath: dest, relativeTo: rootDir).standardizedFileURL
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
              let s = try? Self.decoder.decode(Session.self, from: data)
        else {
            try? fm.removeItem(at: currentLink)
            return nil
        }
        return (s, dir)
    }

    func resume(_ s: Session, directory: URL) {
        session = s
        sessionDir = directory
        images = [:]
        Log.info("resumed session \(s.id): \(s.screens.count) screen(s), \(s.markCount) mark(s)")
    }

    func discardResumable() {
        if let (_, dir) = resumableSession() {
            try? fm.removeItem(at: dir)
        }
        try? fm.removeItem(at: currentLink)
    }

    // MARK: - History

    private func sessionDirectories() -> [URL] {
        let dirs = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Keep the newest `keep` sessions (never the open one).
    func pruneOldSessions(keep: Int = 20) {
        let dirs = sessionDirectories()
        let current = resumableSession()?.directory.standardizedFileURL
        var removed = 0
        for dir in dirs.dropFirst(keep) where dir.standardizedFileURL != current {
            try? fm.removeItem(at: dir)
            removed += 1
        }
        if removed > 0 { Log.info("pruned \(removed) old session(s)") }
    }

    /// Finished sessions (those with a prompt.md), newest first.
    func recentSessions(limit: Int = 10) -> [URL] {
        Array(sessionDirectories()
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("prompt.md").path) }
            .prefix(limit))
    }

    /// Everything on disk, newest first, for the hub.
    struct Summary {
        let directory: URL
        let session: Session
        let isFinished: Bool   // prompt.md exists
        let isOpen: Bool       // the session currently being annotated
        let hasFeedback: Bool  // feedback.md exists (website mode)
    }

    func allSessions() -> [Summary] {
        let openDir = sessionDir?.standardizedFileURL
        return sessionDirectories().compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let session = try? Self.decoder.decode(Session.self, from: data) else { return nil }
            return Summary(
                directory: dir,
                session: session,
                isFinished: fm.fileExists(atPath: dir.appendingPathComponent("prompt.md").path),
                isOpen: dir.standardizedFileURL == openDir,
                hasFeedback: fm.fileExists(atPath: dir.appendingPathComponent(FeedbackComposer.fileName).path)
            )
        }
    }

    /// Delete a finished session from disk. The open session is never deleted here.
    func delete(sessionAt directory: URL) {
        guard directory.standardizedFileURL != sessionDir?.standardizedFileURL else { return }
        try? fm.removeItem(at: directory)
        Log.info("deleted session \(directory.lastPathComponent)")
    }

    static func prompt(in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent("prompt.md"), encoding: .utf8)
    }

    static func feedback(in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(FeedbackComposer.fileName), encoding: .utf8)
    }

    static func ms(since t0: Date) -> Int {
        Int(Date().timeIntervalSince(t0) * 1000)
    }
}
