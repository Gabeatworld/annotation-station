# Annotation Station

A macOS menu-bar app for pointing at things on your screen and saying what's wrong with them.

Press `⌘⇧A` anywhere. The screen under your cursor freezes, and you draw numbered boxes and
arrows on it with a note on each. Repeat on as many screens as you like — they stay in one
session. Then send it: either as a prompt pasted straight into Claude Code, or as a shareable
feedback report that records which page and browser you were looking at.

Local only. Nothing leaves the machine unless you paste it somewhere.

- **[PLAN.md](PLAN.md)** — the original spec, the architecture, and the gotchas that cost time.
- **[ROADMAP.md](ROADMAP.md)** — what's done, what's next, and what was deliberately deferred.

## Requirements

macOS 14 (Sonoma) or later, and a Swift 5.9+ toolchain — the Xcode command line tools are
enough. There is no `.xcodeproj`; it's a Swift package built with `swift build`.

## Setup

Two commands, one of which you only ever run once:

```bash
Scripts/make-signing-cert.sh    # once, ever
Scripts/run.sh                  # build, sign, launch, follow the log
```

`Scripts/run.sh --no-logs` skips the log stream. The app lives in the menu bar; it has no Dock
icon and no window until you ask for one.

### Why the certificate step matters

macOS remembers permission grants by bundle id **plus code requirement**. An ad-hoc signature's
requirement is the binary's hash, which changes on every single build — so every rebuild would
silently lose your Screen Recording grant and the app would quietly stop working.
`Scripts/make-signing-cert.sh` creates a self-signed "Annotation Station Dev" certificate in
your login keychain, which gives a stable identity across rebuilds. `Scripts/bundle.sh` uses it
automatically (and warns loudly if it falls back to ad-hoc).

If `codesign` fails with `errSecInternalComponent`, run this once and rebuild:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
```

If you ever change signing identity, clear the stale grant so macOS prompts cleanly instead of
showing a permission that is on but not working:

```bash
tccutil reset ScreenCapture com.gabe.annotation-station
```

## Permissions

| Permission | Needed for | If you decline |
|---|---|---|
| **Screen Recording** | capturing the display | the app cannot work at all |
| **Accessibility** | pressing `⌘V` in Claude Desktop or Ghostty for you | the prompt is still copied; paste it yourself |
| **Automation** (per browser) | reading the page URL for website feedback | reports carry the screenshots and notes, just no page details |

All three live in System Settings › Privacy & Security. Screen Recording is asked for on first
capture; the other two only when the feature that needs them first runs. Automation is asked
once per browser.

To stop the app talking to browsers entirely:

```bash
defaults write com.gabe.annotation-station websiteContext -bool false
```

## Using it

### Global

| Key | Does |
|---|---|
| `⌘⇧A` | capture the screen under the cursor — or, while annotating, save this screen and go find the next one |
| `⌘⇧⏎` | open the compose panel for the open session |

### While annotating

| Key | Does |
|---|---|
| drag | draw a box |
| right-drag, or `⌥`-drag | draw an arrow (from the thing, to where it should go) |
| `⇧` while drawing | constrain to a square, or to 45° |
| `B` / `A` | box tool / arrow tool |
| click a mark | select it — then drag to move, or drag a corner or arrowhead to reshape |
| `⇥` / `⇧⇥` | cycle through the marks |
| `⌫` | delete the selected mark |
| `⌘Z` / `⌘⇧Z` | undo / redo |
| `N` | save this screen and go capture another |
| `⏎` | open the compose panel |
| `⌘⏎` | send now, skipping compose |
| `⎋` | deselect, or discard this screen if nothing is selected |
| `⌘⎋` | discard the whole session |

Marks are numbered `[1]`, `[2]`, `[3]`… across the whole session, not per screen, so a note on
screen 2 can refer to `[1]` on screen 1. Numbers are derived from order, so deleting a mark
renumbers the rest rather than leaving a gap.

The display you're annotating wears a slow breathing glow around its edge, so on a
multi-monitor desk it's obvious which screen is frozen.

## The two send modes

A `Web / Claude` picker in the overlay toolbar, next to Send, decides where a session goes —
built like the Box/Arrow tool picker so the two read as one set of controls. It's there rather
than in the compose panel because `⌘⏎` sends without opening compose. The compose panel mirrors
the same setting with the same picker.

**Claude Code** (the default) writes `prompt.md` — the annotated PNGs referenced by absolute
path, each mark as a numbered line with its note, and per-mark crops where a crop adds
something. It goes on the clipboard and is pasted into whichever of Claude Desktop or Ghostty
you used most recently, wherever that window is. If neither is running it's copied and focus
goes back to what you were annotating.

**Website feedback** frames each annotated capture like a macOS window screenshot — rounded
card, shadow, gradient backdrop, the page title and URL in the title bar, and a caption line
with browser, viewport, display, time and who filed it. That context is burned into the image
on purpose: pasting a screenshot into Slack, Linear or Notion attaches the file and drops the
text that came with it, so anything that only lives in the text does not survive the paste.

It also writes `feedback.md` — the same marks packaged for a person rather than an agent,
carrying the same environment as the caption plus every mark's note and a link to its crop.
The report and the framed PNGs both go on the clipboard. Which of the two a given app keeps is
up to that app, which is exactly why the picture has to stand on its own.

Both modes always write `prompt.md`, so the hub's Copy Prompt works on any session.

## Sessions on disk

```
~/.annotation-station/
├── current -> sessions/2026-09-07T16-30-12     # only while a session is open
└── sessions/
    └── 2026-09-07T16-30-12/
        ├── session.json               # marks, notes, mode, page context
        ├── screen-1.png               # the untouched capture
        ├── screen-1-annotated.png     # marks burned in
        ├── region-1.png               # per-mark crop, when a crop is useful
        ├── prompt.md
        └── feedback.md                # website mode only
```

The newest 20 sessions are kept; older ones are pruned on launch. If the app dies mid-session,
`current` lets it offer to resume on next launch.

## The hub

Menu bar → **Sessions…** lists everything on disk, grouped by day. Each card shows thumbnails,
the marks and their notes, the page it was captured on, and whether it was sent.

Click a thumbnail (or **View**) to open the screens full size without leaving the app: `←`/`→`
walk the session, `O` flips to the untouched capture, `⎋` closes. Per session you can also copy
the prompt again, copy the feedback report, reveal the folder in Finder, or delete it.

## Distribution and updates

The app is not on the Mac App Store and can't be: the sandbox forbids both the global hotkey
and the Accessibility auto-paste. It ships instead as a notarized `.app` that updates itself
through [Sparkle](https://sparkle-project.org).

`Scripts/release.sh` does the whole cut — Developer ID build, notarize, staple, sign, appcast:

```bash
Scripts/release.sh --keys     # one-time: the EdDSA key pair updates are signed with
Scripts/release.sh 0.2.0      # build + notarize + staple + sign + appcast entry
```

Three one-time things it needs, in order:

1. **An Apple Developer Program membership** ($99/yr) and a *Developer ID Application*
   certificate. Only a Developer ID can be notarized, and only a notarized build opens on
   someone else's Mac without a Gatekeeper detour. `RELEASE=1 Scripts/bundle.sh` refuses to
   run without one rather than producing a build that fails on arrival.
2. **A stored notarization credential**, so no password lives in the repo:
   ```bash
   xcrun notarytool store-credentials "annotation-station" \
       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
   ```
3. **The signing key pair**, from `Scripts/release.sh --keys`. Paste the public half into
   `Resources/Info.plist` under `SUPublicEDKey` and keep the private half somewhere safe — it
   stays in the login keychain, and losing it means existing installs can never verify another
   update. Until that key is filled in, the app disables updates entirely and hides the
   *Check for Updates…* menu item; it will not trust an unsigned feed.

Releases are GitHub Releases, and the appcast is served from the repo itself
(`appcast.xml` on `main`), so pushing the commit is what actually ships an update. That only
works because the repo is public — a private repo's release assets need auth, which Sparkle
has no way to supply.

### Signing layout

Sparkle ships as a framework containing its own XPC services and a helper app, so
`Scripts/bundle.sh` signs inside-out — services, then `Updater.app`, then `Autoupdate`, then
the framework, then the app — and never with `--deep`, which would re-sign nested code with
the outer bundle's options. Dev builds keep using the self-signed certificate so TCC grants
survive rebuilds; release builds switch to the Developer ID and add the hardened runtime,
which notarization requires.

## Development

```bash
swift build        # or: swift build -c release
swift test         # 27 tests, no fixtures, no network
Scripts/run.sh     # bundle + sign + relaunch + logs
```

Logs go to unified logging under the subsystem `com.gabe.annotation-station`. Note the full
path — `zsh` has a `log` builtin that shadows the real one:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.gabe.annotation-station"'
```

### Layout

| Path | What lives there |
|---|---|
| `App/` | delegate and state machine, menu bar, global hotkeys, toasts |
| `Capture/` | ScreenCaptureKit capture, TCC helpers, the browser page probe |
| `Overlay/` | the frozen full-screen window, drawing and hit-testing, HUD chrome, the screen glow |
| `Compose/` | the instruction and notes panel |
| `Session/` | the session model, disk store, renderer, and the two document composers |
| `Hub/` | the Sessions window and the full-size viewer |
| `Output/` | clipboard and auto-paste |
| `App/Updater.swift` | Sparkle auto-updates |

Marks are stored in screen points with a top-left origin; captures are in pixels. The scale
factor is stored per screen and applied only at render time, so the overlay and the burned-in
PNG never drift apart — `Renderer` is shared by both for the same reason.

### Driving the app without touching the keyboard

Useful for taking screenshots of a change, or for smoke tests. Enable once, then relaunch:

```bash
defaults write com.gabe.annotation-station debugHooks -bool true
```

```bash
Scripts/debug.sh capture              # same as ⌘⇧A
Scripts/debug.sh demo                 # drop three demo marks on the open overlay
Scripts/debug.sh compose              # open the compose panel
Scripts/debug.sh snapshot out.png     # the app screenshots its own display, overlay included
Scripts/debug.sh hub | view           # sessions window / full-size viewer
Scripts/debug.sh next | send | discard
```
