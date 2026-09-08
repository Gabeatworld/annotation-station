import CoreGraphics
import Foundation

/// How a finished session is packaged on send (ROADMAP "feedback types"). The pipeline —
/// capture, marks, numbering, annotated PNGs — is the same for every mode; only the document
/// written at the end and where it is delivered differ.
enum CaptureMode: String, Codable, CaseIterable {
    /// `prompt.md` with absolute PNG paths, pasted into Claude Code.
    case llm
    /// `feedback.md`: a human-readable report with the page and browser the marks were made on.
    case website

    var title: String {
        switch self {
        case .llm: return "Claude Code"
        case .website: return "Website feedback"
        }
    }
}

/// What the frontmost browser was showing when a screen was captured. Collected off the main
/// thread so it never delays the overlay, so it can be nil: the annotated app was not a browser
/// we can script, Automation is not granted, or the browser had no open tab.
struct PageContext: Codable, Equatable {
    var browserName: String
    var browserVersion: String
    var bundleID: String
    var url: String
    var pageTitle: String
    /// CSS pixels, from `innerWidth`/`innerHeight`. Needs "Allow JavaScript from Apple Events",
    /// which is off by default in every browser, so treat it as a bonus.
    var viewport: CGSize?

    /// "example.com/pricing" — what a reviewer scans for, without the scheme noise.
    var shortURL: String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let path = components.path == "/" ? "" : components.path
        return host + path
    }
}

/// One annotation session: one or more captured screens plus an optional overall instruction.
/// Persisted as `session.json` next to the PNGs (PLAN.md §3).
struct Session: Codable, Equatable {
    var id: String
    var createdAt: Date
    var screens: [Screen]
    var instruction: String
    var mode: CaptureMode

    init(id: String, createdAt: Date = Date(), screens: [Screen] = [], instruction: String = "", mode: CaptureMode = .llm) {
        self.id = id
        self.createdAt = createdAt
        self.screens = screens
        self.instruction = instruction
        self.mode = mode
    }

    // Hand-written so `session.json` files from before capture modes still decode.
    private enum CodingKeys: String, CodingKey { case id, createdAt, screens, instruction, mode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        screens = try c.decode([Screen].self, forKey: .screens)
        instruction = try c.decode(String.self, forKey: .instruction)
        mode = try c.decodeIfPresent(CaptureMode.self, forKey: .mode) ?? .llm
    }
}

/// One captured display. `index` is 1-based and names the files (`screen-1.png`).
/// Marks are kept in `seq` order; their numbers are derived, never stored.
struct Screen: Codable, Equatable {
    var index: Int
    var displayID: UInt32
    var scale: CGFloat
    var pointSize: CGSize
    var pixelSize: CGSize
    var marks: [Mark]
    var capturedAt: Date
    /// Optional, so old `session.json` files decode unchanged.
    var context: PageContext? = nil
}

/// A box or an arrow, in screen points with a top-left origin.
struct Mark: Codable, Equatable, Identifiable {
    var id: UUID
    var seq: Int
    var kind: Kind
    var note: String

    init(id: UUID = UUID(), seq: Int, kind: Kind, note: String = "") {
        self.id = id
        self.seq = seq
        self.kind = kind
        self.note = note
    }

    enum Kind: Equatable {
        case box(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
    }
}

// MARK: - Kind: explicit JSON so session.json stays inspectable

extension Mark.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, x, y, width, height, fromX, fromY, toX, toY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "box":
            self = .box(CGRect(
                x: try c.decode(CGFloat.self, forKey: .x),
                y: try c.decode(CGFloat.self, forKey: .y),
                width: try c.decode(CGFloat.self, forKey: .width),
                height: try c.decode(CGFloat.self, forKey: .height)
            ))
        case "arrow":
            self = .arrow(
                from: CGPoint(x: try c.decode(CGFloat.self, forKey: .fromX), y: try c.decode(CGFloat.self, forKey: .fromY)),
                to: CGPoint(x: try c.decode(CGFloat.self, forKey: .toX), y: try c.decode(CGFloat.self, forKey: .toY))
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown mark type '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .box(let r):
            try c.encode("box", forKey: .type)
            try c.encode(r.origin.x, forKey: .x)
            try c.encode(r.origin.y, forKey: .y)
            try c.encode(r.width, forKey: .width)
            try c.encode(r.height, forKey: .height)
        case .arrow(let from, let to):
            try c.encode("arrow", forKey: .type)
            try c.encode(from.x, forKey: .fromX)
            try c.encode(from.y, forKey: .fromY)
            try c.encode(to.x, forKey: .toX)
            try c.encode(to.y, forKey: .toY)
        }
    }
}

extension Mark.Kind {
    var isArrow: Bool {
        if case .arrow = self { return true }
        return false
    }

    /// Bounding rect in points. For an arrow this spans tail and head (may have zero width or height).
    var bounds: CGRect {
        switch self {
        case .box(let r):
            return r.standardized
        case .arrow(let a, let b):
            return CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(b.x - a.x), height: abs(b.y - a.y)
            )
        }
    }

    func offset(by d: CGPoint) -> Mark.Kind {
        switch self {
        case .box(let r):
            return .box(r.offsetBy(dx: d.x, dy: d.y))
        case .arrow(let a, let b):
            return .arrow(from: CGPoint(x: a.x + d.x, y: a.y + d.y), to: CGPoint(x: b.x + d.x, y: b.y + d.y))
        }
    }
}

// MARK: - Numbering (derived from (screen.index, mark.seq); dense 1…n across the session)

struct NumberedMark: Equatable {
    let number: Int
    let screenIndex: Int
    let mark: Mark
}

extension Session {
    var orderedScreens: [Screen] { screens.sorted { $0.index < $1.index } }

    var numberedMarks: [NumberedMark] {
        var n = 0
        var out: [NumberedMark] = []
        for screen in orderedScreens {
            for mark in screen.marks.sorted(by: { $0.seq < $1.seq }) {
                n += 1
                out.append(NumberedMark(number: n, screenIndex: screen.index, mark: mark))
            }
        }
        return out
    }

    var markCount: Int { screens.reduce(0) { $0 + $1.marks.count } }

    /// Number of marks on screens that come before `index`; the first mark on that screen is offset + 1.
    func numberOffset(forScreenIndex index: Int) -> Int {
        screens.filter { $0.index < index }.reduce(0) { $0 + $1.marks.count }
    }

    func number(of markID: UUID) -> Int? {
        numberedMarks.first { $0.mark.id == markID }?.number
    }
}

extension Screen {
    /// Marks in numbering order.
    var orderedMarks: [Mark] { marks.sorted { $0.seq < $1.seq } }
}

extension Session {
    /// The page the session is about: the first screen that has one.
    var primaryContext: PageContext? { orderedScreens.compactMap(\.context).first }
}
