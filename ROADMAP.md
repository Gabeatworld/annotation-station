# Annotation Station — Roadmap

Status (2026-09-07): M0–M3 from PLAN.md are done and in use. Visual affordance pass done
(toolbar, title strip, note labels, cursors, toasts). The Sessions hub is done, and so are the
first two capture modes (Claude Code, website feedback). Ideas below are ordered by what Gabe
asked for first; nothing here is committed to a date.

## Done: Hub (session browser)
Menu bar → "Sessions…" lists past captures grouped by day, then by session, with a thumbnail,
mark count, notes preview and the instruction. Per-session actions: view, copy prompt again,
copy feedback, reveal the folder in Finder, delete. Clicking a thumbnail (or "View") opens the
screens full size in-app — arrow keys walk the session, `O` flips to the original capture.
Still open: re-send to Claude/Ghostty from the hub, reopening a session to add screens or edit
notes, search and filters.

## Done: Which screen is selected
The display carrying the overlay wears a Siri-style breathing glow around its edge, so a
multi-monitor desk shows at a glance which screen is frozen. Tuned to stay out of the way:
a narrow band, a shallow pulse, and a lap of the colour wheel that takes the best part of a
minute, on a pale red/orange/pink/violet/blue palette anchored to the #C3C3EF mark accent. Both the colour sweep and the
edge falloff are baked once per screen size; only an opacity pulse and a layer rotation run
per frame, and both stop when the overlay is ordered out or the user asks for reduced motion.

## Feedback types (capture "modes")
The same capture + marks pipeline, different packaging on send. A session carries a
`CaptureMode`; a `Web / Claude` segmented picker in the overlay toolbar next to Send chooses it
— so ⌘⏎, which skips the compose panel entirely, respects the choice — and the compose panel
mirrors it with the same control. Both are built like the Box/Arrow tool picker, so the toolbar
reads as one set of controls rather than a row of mixed widgets.
`finalize` writes the matching document. `prompt.md` is written in every mode so the hub's
Copy Prompt always works.
- **LLM feedback** (done): `prompt.md` with absolute PNG paths, pasted into Claude Code.
- **Website feedback** (done): `feedback.md` — a human-readable report with relative image
  links, the page URL and title, browser name and version, viewport, display size and scale,
  and who filed it. Sending copies it — with the annotated PNGs attached as file items, so
  pasting into Slack, Linear or a doc carries the images — and hands focus back to the browser
  instead of pasting into an agent; the hub grows a "Copy Feedback" button.
  - Still missing for a full review flow: a *link* a reviewer can open. The Markdown's image
    links are relative to the session folder, so the report travels intact only as that folder
    or via the attached PNGs. Hosting is the "Sharing and teams" item below.
  - The URL comes from the frontmost browser over Apple events (Safari and every Chromium
    browser; Firefox does not expose its tabs). macOS asks once per browser under Privacy &
    Security › Automation — before that grant a report still has the screenshots and notes,
    just no page details. Turn the whole thing off with
    `defaults write com.gabe.annotation-station websiteContext -bool false`.
  - Viewport is only available when "Allow JavaScript from Apple Events" is on in the
    browser's developer menu, so it is omitted more often than not.
- **Framed screenshot** (done, website mode only): marks are burned in, then the capture is
  framed like a macOS window screenshot — rounded card, drop shadow, gradient backdrop, three
  window dots, the page title and URL centred in the title bar, each note burned in beside its
  own mark, the same notes listed under the capture against their badge numbers, and a caption
  line carrying browser, viewport, display, time and reporter.
  The caption is the point, not decoration: a pasted screenshot nearly always arrives alone,
  because Slack, Linear and Notion take the image file off the pasteboard and drop the text
  that came with it. Burning the context into the picture is what makes a paste self-contained.
  The agent path keeps the bare capture — a frame and a caption there would only cost tokens.

## Sharing and teams (later)
- **Distribution** (plumbing done): the app embeds Sparkle and updates itself from an appcast
  served out of this repo; `Scripts/release.sh` builds with a Developer ID, notarizes, staples,
  signs and writes the appcast entry. The repo was made public so release assets are fetchable
  without auth. Still blocked on an Apple Developer Program membership — until there is a
  Developer ID certificate and an `SUPublicEDKey`, both scripts refuse to produce a notarized
  release and the app hides its update menu rather than trusting an unsigned feed.
  `Scripts/release.sh --unnotarized` ships today without a membership: everything works except
  the first launch, which each person clears once by hand (`dist/INSTALL.md` explains it). Mac App Store is out:
  the sandbox forbids the global hotkey and the Accessibility auto-paste.
- Shared spaces: a session is uploadable to a shared feedback board for a team.
  Needs a backend or a shared folder; decide once the hub exists.

## Polish backlog
- Image pasteboard fallback if a target ever stops reading paths.
- Multi-display overlays (⌘⇧A on another display adds it as a screen).
- Freehand pen, ellipse, text labels; per-mark color; configurable hotkeys (PLAN.md M4).
- App icon.
