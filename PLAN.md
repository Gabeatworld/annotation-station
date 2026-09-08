# Annotation Station — MVP Plan

A local, open clone of [Casso](https://usecasso.app): a macOS menu-bar app that lets you draw numbered
boxes on your screen, attach notes, and hand the annotated screenshots + a prompt to a coding agent
(Claude Code first). Three things matter more than feature parity with Casso:

1. **Speed of the feedback loop.** Hotkey → marks → send should take seconds. No dialogs, no mouse trips to a
   toolbar, keyboard for everything after the drag.
2. **Arrows, not just boxes.** Boxes say *where*; arrows say *what should happen* ("move this here",
   "this should line up with that"). Arrows are numbered marks like boxes and are in M1, not a later polish item.
3. **Multi-screen sessions.** Annotate screen A, dismiss the overlay, click through the app to screen B,
   annotate it, and so on — then send *one* prompt covering all screens with mark numbers that keep
   counting across screens. Casso is one capture per send; this is the main thing we improve on.

Mac only. No Windows. No LLM calls, no network, no telemetry. Everything on disk under `~/.annotation-station/`.

---

## 0. Landscape (what exists, and what we take from each)

| Tool | Kind | What it does well | Gap for us |
|---|---|---|---|
| [Casso](https://usecasso.app) | Mac/Win menu-bar app, $29 | Hotkey overlay, numbered boxes + notes, writes `prompt.md` + PNG to a temp session, clipboard/auto-paste. The reference UX. | Boxes only, one capture per send, closed source. |
| [macshot](https://github.com/sw33tLie/macshot) | Open-source Swift screenshot tool | Native overlay → selection → annotation pipeline in Swift; good reference code for `ScreenCaptureKit`, overlay windows, and burn-in rendering. | General screenshot tool; no numbering, no prompt output, no sessions. |
| [Capso](https://github.com/lzhgus/Capso) | Open-source Swift 6 / SwiftUI CleanShot clone | System-wide configurable hotkeys, annotation editor with arrows. Reference for hotkey handling and arrow drawing. | Same: not agent-oriented. |
| [Agentation](https://github.com/benjitaylor/agentation) | npm overlay for your own web app | Click a DOM element, comment, copy Markdown with selector / component / position. Batches many comments into one output. | Only works inside a web app you control on localhost. Useless for native apps, other people's sites, Figma, terminals. |
| [Vibe Annotations](https://www.vibe-annotations.com/) | Chrome extension + local MCP server | DOM selection + React component + zoned screenshot per annotation, delivered via MCP. | Browser-only, localhost-only. |
| [stagewise](https://stagewise.io) | Browser toolbar + its own agent | "Point at an element and tell the agent." | Tied to their agent; web-only. |
| [Annotate](https://www.producthunt.com/products/annotate-8) | Screen recording + voice + drawing → video prompt | Draw and talk over a recording. | Video is heavy for agents; slow loop. |
| [SlimSnap](https://slimsnap.ai) | Scrolling capture + MCP | Hands captures to agents as structured data. | No annotation intent. |

**Takeaways.** Screen-level (not DOM-level) is the right layer for us: it works on anything on screen and
doesn't need instrumentation. The DOM tools win on *batching many comments into one send*, which is exactly
the multi-screen session idea, and on structured output, which we get from numbered marks + `prompt.md`.
Casso's own [blog on effective annotations](https://usecasso.app/blog/annotate-screenshots-claude-code) is
a good design constraint: the value is the shared coordinate system between text and image (`[1]`, `[2]`),
one issue per mark, and relational instructions ("`[2]` should left-align with `[1]`"). Arrows make the
relational case visual instead of verbal.

Steal from macshot/Capso: the capture + overlay + arrow-rendering code paths. Don't fork them; they carry a
lot of unrelated features. Read them, then write the ~1.5k lines we actually need.

---

## 1. Stack

| Choice | Decision | Why |
|---|---|---|
| Language / UI | Swift 5.9+, AppKit (no SwiftUI for the overlay; SwiftUI OK for settings later) | Borderless transparent key windows, per-display overlays, CoreGraphics drawing, and CGEvent-based paste are all native. Electron/Tauri fight you on every one of these. |
| Build | Swift Package Manager executable target + a `Scripts/bundle.sh` that wraps the binary into `AnnotationStation.app` with an `Info.plist` | No `.xcodeproj` to maintain; `swift build` from the terminal. A real `.app` bundle is required so macOS remembers the Screen Recording / Accessibility grants for a stable bundle id instead of attributing them to Terminal. |
| Screen capture | `ScreenCaptureKit` → `SCScreenshotManager.captureImage` (macOS 14+) | Modern API, retina-correct, per-display. Fall back to `CGDisplayCreateImage` only if SCK is a problem. |
| Global hotkey | Carbon `RegisterEventHotKey` (or the `soffes/HotKey` SPM package which wraps it) | Works without Accessibility permission. `NSEvent.addGlobalMonitorForEvents` would need Accessibility. |
| Persistence | JSON `session.json` + PNGs on disk | Trivially inspectable; the agent reads the files directly anyway. |
| Deps | `soffes/HotKey` only (optional) | Keep it to zero or one dependency. |
| Min macOS | 14 (Sonoma). Dev machine is 15.7. | SCK screenshot API. |

Not doing: Windows, cloud, licensing, auto-update, App Store.

---

## 2. User flow (the spec)

### Keys
| Key | Where | Action |
|---|---|---|
| `⌘⇧A` | anywhere | **Capture**: freeze the display under the cursor and show the overlay. If a session is already open, this starts the *next screen* in that session. |
| left-drag | overlay | Draw a **box**. It gets the next global number `[n]` and a note field pops up anchored to it. |
| right-drag or `⌥`-drag | overlay | Draw an **arrow** from tail to head. Same numbering and note popover (anchored at the tail). No mode switch needed. |
| `B` / `A` | overlay | Set the default tool for left-drag (box / arrow). Status shown bottom-left of overlay. |
| `⇧` while dragging | overlay | Box: constrain to square. Arrow: snap angle to 45° increments. |
| type + `⏎` | note field | Commit note (empty note is fine). Focus returns to overlay. |
| `⎋` in note field | | Cancel note edit (mark stays). |
| `⌫` / `⌦` | overlay, a mark selected | Delete selected mark; renumber everything after it (across screens). |
| click on mark | overlay | Select it (box body/edge, or within 6pt of an arrow line). Double-click reopens its note. Drag a selected mark to move it; drag a box corner or arrow endpoint to resize/reroute. |
| `⌘Z` / `⌘⇧Z` | overlay | Undo / redo on this screen. |
| `⇥` / `⇧⇥` | overlay | Cycle mark selection. |
| `N` or `⌘⇧A` again | overlay | **Next screen**: commit this screen to the session, hide the overlay, return to the app. Menu-bar icon shows `2 · 5` (screens · marks). |
| `⏎` (no field focused) | overlay | **Compose**: commit this screen, open the compose panel to type an overall instruction, then send. |
| `⌘⏎` | overlay | **Send now**: commit this screen and send immediately, no compose panel. Intent lives in the mark notes. |
| `⌘⇧⏎` | anywhere | Send the open session from wherever you are (opens compose; `⌘⏎` inside it sends). |
| `⎋` | overlay, no mark selected | Discard *this screen* (confirm only if it has marks). Session stays open if it has earlier screens. |
| `⌘⎋` | overlay | Discard the whole session (confirm). |

### Compose panel (optional)
A small floating window: one multiline text field for the overall instruction ("Fix cards on [1] to match [3]"),
a list of `[n] note` lines you can click to edit, and **Send** (`⌘⏎`). The instruction field is pre-focused.
It exists for relational asks that don't belong to a single mark; when the notes already say everything,
`⌘⏎` from the overlay skips it entirely. Both routes are the same loop:
`⌘⇧A → drag → note → ⏎ → (instruction) → ⌘⏎`.

### Send = copy, then paste if we know where
Send always writes the prompt text to the clipboard. If the app that was frontmost before the overlay
opened is one of the known targets, Send also re-activates it and posts `⌘V` (needs Accessibility; if
denied, it just copies and flashes "copied"). Known targets for MVP: **Claude Desktop** (`com.anthropic.claudefordesktop`)
and **Ghostty** (`com.mitchellh.ghostty`). Anything else: clipboard only. No settings UI; the target list is a constant.

### Freeze-frame, not live overlay
Capture the screenshot *first*, then show it full-screen in the overlay with boxes drawn over it. Casso
draws on a transparent overlay and captures on confirm; freeze-frame is simpler (no compositing the
overlay out of the capture), stable (the UI can't change under you), and it's what CleanShot does.

### Multi-monitor
Capture the display containing the mouse cursor. One overlay window sized to that `NSScreen`. Other
displays are untouched. (Later: one overlay per display, `⌘⇧A` on another display adds it as a screen.)

---

## 3. Session model

```
~/.annotation-station/sessions/2026-09-07T16-30-12/
  session.json
  screen-1.png            # raw capture, pixel size (retina)
  screen-1-annotated.png  # boxes + number badges burned in
  screen-2.png
  screen-2-annotated.png
  region-1.png            # crop of [1] at full pixel resolution (+8px padding; arrows crop their bounding rect)
  region-2.png
  region-3.png
  prompt.md
```

```swift
struct Session: Codable { var id: String; var createdAt: Date; var screens: [Screen]; var instruction: String }
struct Screen  : Codable { var index: Int; var displayID: UInt32; var scale: CGFloat; var pointSize: CGSize;
                           var pixelSize: CGSize; var marks: [Mark]; var capturedAt: Date }
struct Mark    : Codable { var seq: Int; var kind: Kind; var note: String                        // number is derived, not stored
                           enum Kind: Codable { case box(CGRect); case arrow(from: CGPoint, to: CGPoint) } } // screen points
```

Mark numbers are global across the session, dense (1…n), and derived from `(screen.index, seq)`.
Pixel coords = point coords × `scale`. Every mark gets a `region-n.png` crop: for a box it's the box, for an
arrow it's the bounding rect of tail+head so the agent sees both ends in one image.
`session.json` is rewritten on every mutation so a crash loses nothing. `~/.annotation-station/current`
is a symlink to the open session, if any.

Keep the last 20 sessions; prune older ones on launch.

---

## 4. Prompt format (`prompt.md`)

Text on the clipboard, absolute paths. Claude Code, in Ghostty or in the Claude Desktop app's Code tab, will
`Read` the PNGs when it sees paths, so this works for any number of screens; pasting a single image via `⌃V`
does not scale to multi-screen. Text only on the pasteboard: a second image item makes some apps paste the
image and drop the text. M3 verifies this against both targets and adds a text+image fallback only if needed.

```markdown
Annotated screenshots follow. Each screen is an image with numbered marks; [n] refers to a mark.
Boxes mark a region. Arrows point from a thing to where it should go or what it should relate to.
Read every image before answering.

## Screen 1 — /Users/Gabe/.annotation-station/sessions/2026-09-07T16-30-12/screen-1-annotated.png
- [1] card grid is misaligned with the header   (crop: …/region-1.png)
- [2] this should be the primary button

## Screen 2 — /Users/Gabe/.annotation-station/sessions/2026-09-07T16-30-12/screen-2-annotated.png
- [3] match the spacing of [1]
- [4] (arrow) move the filter chips up into the toolbar here

## Instruction
Fix the card grid so [1] lines up with the header, and make [2] use the same spacing as [3].
```

Rules: arrows are prefixed `(arrow)`; omit the `(crop: …)` suffix if the mark is larger than 60% of the screen (crop is pointless);
omit the `## Instruction` section if empty; one screen with one region still gets the same shape.
A `Settings → Prompt template` is out of scope for MVP, but keep the composer as a pure function
`render(session) -> String` so it's trivial to add.

---

## 5. Architecture

```
Sources/AnnotationStation/
  App/
    main.swift                 // NSApplication, LSUIElement, hotkey registration
    AppDelegate.swift          // wires everything, owns SessionStore + StatusItem
    StatusItemController.swift // menu-bar icon, "2 · 5" badge, menu: Capture, Send, Discard, Recent sessions, Settings, Quit
  Capture/
    ScreenCapturer.swift       // SCK screenshot of display under cursor → (CGImage, NSScreen, scale)
    Permissions.swift          // CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess, AXIsProcessTrusted
  Overlay/
    OverlayWindow.swift        // borderless, level .screenSaver, canBecomeKey = true, covers one NSScreen
    OverlayView.swift          // draws frozen capture + marks + badges; left-drag box / right-drag arrow; hit-testing; move/resize; key handling
    MarkGeometry.swift         // arrow head math, hit-test distance to segment, corner handles, snapping
    NotePopover.swift          // small NSTextField floating at box corner; ⏎ commits, ⎋ cancels
  Session/
    Models.swift               // Session / Screen / Mark (Codable)
    SessionStore.swift         // create / current / commitScreen / deleteRegion+renumber / finalize / prune
    Renderer.swift             // burn boxes, arrows, badges into CGImage; crop per mark; write PNGs
    PromptComposer.swift       // render(session) -> String  (pure, unit-tested)
  Output/
    Clipboard.swift            // NSPasteboard string (+ optionally the first annotated image as a second item)
    AutoPaste.swift            // remember previous frontmost NSRunningApplication; activate; CGEvent ⌘V
Tests/AnnotationStationTests/
    PromptComposerTests.swift
    GeometryTests.swift        // points↔pixels, renumbering after delete, crop padding/clamping, arrow hit-test
Scripts/
    bundle.sh                  // swift build -c release → AnnotationStation.app (Info.plist, icon, codesign --sign -)
    run.sh                     // bundle + open
Resources/Info.plist           // CFBundleIdentifier com.gabe.annotation-station, LSUIElement=true,
                               // NSScreenCaptureUsageDescription, NSAppleEventsUsageDescription
```

State machine in `AppDelegate`:
`idle → capturing → annotating(screen k) → [next] → idle-with-open-session → capturing → … → composing → idle`.
The status item reflects the state; `⌘⇧⏎` is only enabled when a session is open.

---

## 6. Milestones (each is one Opus session; each ends with a runnable app)

### M0 — Skeleton (½ day)
- SPM package, `bundle.sh`, `run.sh`, menu-bar icon with Quit.
- `⌘⇧A` logs "capture" to console. Permission preflight + request for Screen Recording on first capture.
- **Done when:** app launches from `Scripts/run.sh`, lives in the menu bar, hotkey fires, permission prompt appears once and is remembered on relaunch.

### M1 — Single screen, end to end (1 day)
- Capture display under cursor → overlay with freeze-frame → left-drag boxes, right-drag arrows → note popover → `⏎` → compose panel → **Copy**.
- Renderer writes `screen-1.png`, `screen-1-annotated.png`, `region-n.png`, `prompt.md`, `session.json`.
- Mark styling: 3pt stroke in a high-contrast color (`#FF3B30`) with a 1pt white outer halo so it reads on any background; 22pt circular badge with white number (box: top-left corner, outside the box; arrow: at the tail). Arrow head is a filled triangle ~14pt long. Dim the area outside boxes by 20% so boxes pop; arrows don't dim.
- Select, move, resize/reroute marks. `⎋` discards. `⌘Z` undo. `⌫` deletes + renumbers.
- **Done when:** paste into Claude Code and it reads the image, answers about `[1]`, `[2]`, and correctly describes where arrow `[3]` points. This is Casso parity plus arrows.

### M2 — Multi-screen sessions (1 day) ← the differentiator
- `N` / second `⌘⇧A` commits the screen and hides the overlay; session stays open; status item shows `screens · marks`.
- Numbering continues across screens; delete-and-renumber spans screens.
- `⌘⇧⏎` from anywhere opens compose. Compose panel lists all marks grouped by screen, editable notes.
- `⌘⎋` discards session; relaunch after crash offers to resume `current`.
- **Done when:** annotate three different screens of an app, send once, Claude Code reads all three images and references `[1]`–`[n]` correctly.

### M3 — Auto-paste + speed polish (½ day)
- **Auto-paste**: remember frontmost app before overlay; if it's Claude Desktop or Ghostty, re-activate it and post `CGEvent` `⌘V`. Ask for Accessibility with a one-line explanation; degrade to copy-only if denied.
- Verify by hand in both targets: the pasted text lands in the input, Claude reads every PNG path, and `[n]` references resolve. If the Desktop app's Code tab doesn't read paths, add an image pasteboard item as a fallback for that target only.
- Latency budget: hotkey → overlay visible < 150 ms (capture async, show overlay with a black frame then swap in the image if needed). Overlay → clipboard after `⌘⇧⏎` < 300 ms.
- Sound/flash on send so you know it landed without looking at the menu bar.
- "Recent sessions" submenu → re-copy prompt.
- **Done when:** `⌘⇧A`, drag, type note, `⏎`, type instruction, `⌘⇧⏎` lands the prompt in a Claude Code terminal with no mouse use after the drag.

### M4 — Nice-to-haves (only after M3 is in daily use)
- Freehand pen and circle/ellipse tools; per-mark color; text labels placed directly on the image.
- Configurable hotkeys, prompt template, sessions dir, box color (simple `Settings.json`, edit in `$EDITOR`).
- Window-scoped capture (pick a window instead of a display).
- Per-target paste behaviour and a user-editable target list in `Settings.json`.
- Multi-display overlays.

---

## 7. Implementation notes / gotchas for the implementer

- **Retina.** Overlay works in points; captures are in pixels. Store `scale = NSScreen.backingScaleFactor` per screen and convert at render time only. Test at 1x and 2x. SCK returns the image at pixel size when `configuration.width/height` are set to `display.width * scale`.
- **Key window.** A borderless `NSWindow` returns `false` from `canBecomeKey` by default — override it, and call `NSApp.activate(ignoringOtherApps: true)` before `makeKeyAndOrderFront`, otherwise keystrokes go to the app underneath. `LSUIElement` apps can still activate.
- **Window level.** `.screenSaver` sits above menu bar and Dock. Set `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it shows over full-screen apps.
- **Permissions and bundles.** TCC keys grants by bundle id + code *requirement*. Ad-hoc signing does **not** work here (this note was wrong in the original plan): an ad-hoc designated requirement is `cdhash H"…"`, which changes on every build, so each rebuild loses the Screen Recording / Accessibility grant. Run `Scripts/make-signing-cert.sh` once to create the self-signed "Annotation Station Dev" certificate; `Scripts/bundle.sh` signs with it (and falls back to ad-hoc with a warning). If codesign fails with `errSecInternalComponent`, run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`. After changing signing identity, `tccutil reset ScreenCapture com.gabe.annotation-station` clears the stale "on but denied" entry. Run the `.app`, never the bare binary, when testing permissions.
- **Restoring focus for auto-paste.** Capture `NSWorkspace.shared.frontmostApplication` *before* activating the overlay. On send: order out all windows, `previousApp.activate()`, wait ~100 ms, then post `⌘V` via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `.maskCommand`. Claude Code in Terminal/iTerm/Ghostty accepts a plain paste.
- **Clipboard.** `NSPasteboard.general.clearContents()` then `setString(_:forType: .string)`. If you also add the PNG as a second item, put the string item first — Claude Code will otherwise paste the image and drop the text.
- **Hotkey while overlay is open.** The Carbon hotkey still fires when our own window is key; route it through the state machine (`annotating → next screen`), don't re-capture blindly.
- **Cursor.** Hide the system cursor in the capture (SCK `showsCursor = false`) and use a crosshair cursor in the overlay.
- **Region crop clamping.** Pad crops by 8 px and clamp to the image bounds; a zero-area drag (< 4×4 pt) should be ignored, not create a box.
- **Arrow rendering.** Draw the shaft as a line ending short of the head by the head length, then the head as a filled triangle rotated to the shaft angle; otherwise the shaft pokes through the tip. Round line caps. Hit-test arrows by distance-to-segment ≤ 6pt; hit-test endpoints first (8pt radius) so rerouting wins over moving.
- **Right-drag on macOS.** `rightMouseDown/Dragged/Up` are separate NSView callbacks; also treat `⌥`+left-drag as arrow so trackpad users without a right-click gesture aren't stuck.
- **Renumbering.** Numbers are derived from order `(screen.index, mark.seq)`; compute them, don't store them as truth — deletion then never leaves gaps.

---

## 8. Decisions (confirmed 2026-09-07)

- **Hotkey:** `⌘⇧A`, same as Casso. It shadows Chrome's "search tabs" shortcut; accepted.
- **Targets:** Claude Code running in the **Claude Desktop app** and in **Ghostty**. Auto-paste is wired for exactly those two bundle ids; every other app gets clipboard-only. Cursor/Codex are not targets.
- **Handoff:** text with absolute file paths, text-only pasteboard. Image fallback only if M3 testing shows the Desktop app needs it. *(Amended: website-feedback mode does attach the annotated PNGs as file items, because its targets are Slack/Linear/docs rather than an agent. The agent path is unchanged.)*
- **Compose panel:** optional. `⏎` opens it for an overall instruction; `⌘⏎` sends straight from the overlay with notes only.
- **Sessions:** `~/.annotation-station/sessions/<timestamp>/`, last 20 kept.
- Mac only, Sonoma+. Single user, no licensing or distribution.
- Boxes and arrows for MVP; no freehand, circles, or text labels.
- One display per capture in MVP.
