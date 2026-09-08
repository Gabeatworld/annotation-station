import XCTest
@testable import AnnotationStation

/// Round-trips session.json and runs the real finalize pipeline on a synthetic capture.
final class SessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-station-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testMarkKindJSONIsExplicit() throws {
        let mark = Mark(seq: 3, kind: .arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4)), note: "n")
        let data = try SessionStore.encoder.encode(mark)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\" : \"arrow\""))
        XCTAssertTrue(json.contains("\"fromX\" : 1"))
        let back = try SessionStore.decoder.decode(Mark.self, from: data)
        XCTAssertEqual(back, mark)
    }

    func testFinalizeWritesEveryFileAndClosesSession() throws {
        let store = SessionStore(rootDir: root)
        try store.beginSessionIfNeeded()
        let screen = try store.addScreen(image: image(width: 400, height: 300), displayID: 7, scale: 2, pointSize: CGSize(width: 200, height: 150))
        XCTAssertEqual(screen.index, 1)
        store.updateMarks(screenIndex: 1, marks: [
            Mark(seq: 1, kind: .box(CGRect(x: 20, y: 20, width: 60, height: 40)), note: "first"),
            Mark(seq: 2, kind: .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 40)), note: "second"),
        ])
        store.setInstruction("do it")
        let dir = try XCTUnwrap(store.sessionDir)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: store.currentLink.path), dir.path)

        let done = expectation(description: "finalize")
        var delivery: SessionStore.Delivery?
        store.finalize { result in
            delivery = try! result.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let prompt = try XCTUnwrap(delivery).text
        XCTAssertEqual(try XCTUnwrap(delivery).mode, .llm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("feedback.md").path))

        for name in ["session.json", "screen-1.png", "screen-1-annotated.png", "region-1.png", "region-2.png", "prompt.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name) missing")
        }
        let annotated = try XCTUnwrap(Renderer.loadPNG(from: dir.appendingPathComponent("screen-1-annotated.png")))
        XCTAssertEqual(annotated.width, 400)
        XCTAssertEqual(annotated.height, 300)
        let region1 = try XCTUnwrap(Renderer.loadPNG(from: dir.appendingPathComponent("region-1.png")))
        XCTAssertEqual(region1.width, 268)   // 160pt minimum @2x + padding, clamped to the 400px image
        XCTAssertEqual(region1.height, 248)  // same, clamped to the 300px image
        XCTAssertEqual(prompt, try String(contentsOf: dir.appendingPathComponent("prompt.md"), encoding: .utf8))
        XCTAssertTrue(prompt.contains("- [2] (arrow) second"))
        XCTAssertTrue(prompt.hasSuffix("## Instruction\ndo it\n"))

        XCTAssertFalse(store.isOpen)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: store.currentLink.path))
        XCTAssertEqual(store.recentSessions().map { $0.lastPathComponent }, [dir.lastPathComponent])
        let decoded = try SessionStore.decoder.decode(Session.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        XCTAssertEqual(decoded.markCount, 2)
        XCTAssertEqual(decoded.instruction, "do it")
    }

    /// Website mode writes feedback.md *as well as* prompt.md, and delivers the feedback.
    func testWebsiteModeFinalizeWritesFeedback() throws {
        let store = SessionStore(rootDir: root)
        try store.beginSessionIfNeeded()
        _ = try store.addScreen(image: image(width: 400, height: 300), displayID: 7, scale: 2, pointSize: CGSize(width: 200, height: 150))
        store.updateMarks(screenIndex: 1, marks: [
            Mark(seq: 1, kind: .box(CGRect(x: 20, y: 20, width: 60, height: 40)), note: "the price is cut off"),
        ])
        store.setMode(.website)
        store.setContext(screenIndex: 1, context: PageContext(
            browserName: "Safari", browserVersion: "18.6", bundleID: "com.apple.Safari",
            url: "https://example.com/pricing", pageTitle: "Pricing", viewport: nil
        ))
        let dir = try XCTUnwrap(store.sessionDir)

        let done = expectation(description: "finalize")
        var delivery: SessionStore.Delivery?
        store.finalize { result in
            delivery = try! result.get()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        let d = try XCTUnwrap(delivery)
        XCTAssertEqual(d.mode, .website)
        for name in ["prompt.md", "feedback.md", "screen-1-annotated.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name) missing")
        }
        XCTAssertEqual(d.text, try String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8))
        XCTAssertTrue(d.text.contains("example.com/pricing"))
        XCTAssertTrue(d.text.contains("Safari 18.6"))
        XCTAssertTrue(d.text.contains("- **[1]** the price is cut off"))

        // The mode and the page survive the round trip through session.json.
        let decoded = try SessionStore.decoder.decode(Session.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        XCTAssertEqual(decoded.mode, .website)
        XCTAssertEqual(decoded.primaryContext?.url, "https://example.com/pricing")

        let summary = try XCTUnwrap(SessionStore(rootDir: root).allSessions().first { $0.directory.lastPathComponent == dir.lastPathComponent })
        XCTAssertTrue(summary.hasFeedback)
    }

    func testResumeAndPrune() throws {
        let store = SessionStore(rootDir: root)
        try store.beginSessionIfNeeded()
        _ = try store.addScreen(image: image(width: 40, height: 30), displayID: 1, scale: 1, pointSize: CGSize(width: 40, height: 30))
        let dir = try XCTUnwrap(store.sessionDir)

        // A fresh store (simulating relaunch after a crash) sees the session via `current`.
        let fresh = SessionStore(rootDir: root)
        let resumable = try XCTUnwrap(fresh.resumableSession())
        XCTAssertEqual(resumable.directory.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(resumable.session.screens.count, 1)
        fresh.resume(resumable.session, directory: resumable.directory)
        XCTAssertNotNil(fresh.image(forScreen: 1) ?? {
            // The raw PNG is written asynchronously; give it a moment.
            Thread.sleep(forTimeInterval: 0.5)
            return fresh.image(forScreen: 1)
        }())

        // Prune keeps the newest N but never the open session.
        for i in 0..<25 {
            try FileManager.default.createDirectory(at: store.sessionsDir.appendingPathComponent("2000-01-01T00-00-\(String(format: "%02d", i))"), withIntermediateDirectories: true)
        }
        fresh.pruneOldSessions(keep: 20)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.sessionsDir.path)
        XCTAssertEqual(remaining.count, 20)
        XCTAssertTrue(remaining.contains(dir.lastPathComponent))
    }
}
