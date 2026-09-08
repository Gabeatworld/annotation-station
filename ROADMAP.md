# Annotation Station — Roadmap

Status (2026-09-07): M0–M3 from PLAN.md are done and in use. Visual affordance pass done
(toolbar, title strip, note labels, cursors, toasts). The Sessions hub is done, and so are the
first two capture modes (Claude Code, website feedback). Ideas below are ordered by what Gabe
asked for first; nothing here is committed to a date.

## Done: Hub (session browser)
Menu bar → "Sessions…" lists past captures grouped by day, then by session, with a thumbnail,
mark count, notes preview and the instruction. Per-session actions: copy prompt again, reveal
the folder in Finder, delete. Still open: re-send to Claude/Ghostty from the hub, reopening a
session to add screens or edit notes, search and filters.

## Feedback types (capture "modes")
The same capture + marks pipeline, different packaging on send. A session carries a
`CaptureMode`; the compose panel picks it ("Send as"), and `finalize` writes the matching
document. `prompt.md` is written in every mode so the hub's Copy Prompt always works.
- **LLM feedback** (done): `prompt.md` with absolute PNG paths, pasted into Claude Code.
- **Website feedback** (done): `feedback.md` — a human-readable report with relative image
  links, the page URL and title, browser name and version, viewport, display size and scale,
  and who filed it. Sending copies it and hands focus back to the browser instead of pasting
  into an agent; the hub grows a "Copy Feedback" button.
  - The URL comes from the frontmost browser over Apple events (Safari and every Chromium
    browser; Firefox does not expose its tabs). macOS asks once per browser under Privacy &
    Security › Automation — before that grant a report still has the screenshots and notes,
    just no page details. Turn the whole thing off with
    `defaults write com.gabe.annotation-station websiteContext -bool false`.
  - Viewport is only available when "Allow JavaScript from Apple Events" is on in the
    browser's developer menu, so it is omitted more often than not.
- **Next: pretty screenshot**: burn marks in, then frame the capture like macOS's ⌘⇧3 device
  mockup (rounded window, shadow, gradient backdrop) for sharing in Slack/docs.

## Sharing and teams (later)
- Keep everything local first. Add "push an update" so the app can be distributed to
  Gabe's company and agency teams (signed + notarized build, Sparkle-style updates).
- Shared spaces: a session is uploadable to a shared feedback board for a team.
  Needs a backend or a shared folder; decide once the hub exists.

## Polish backlog
- Image pasteboard fallback if a target ever stops reading paths.
- Multi-display overlays (⌘⇧A on another display adds it as a screen).
- Freehand pen, ellipse, text labels; per-mark color; configurable hotkeys (PLAN.md M4).
- App icon.
