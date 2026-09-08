# Annotation Station — Roadmap

Status (2026-09-07): M0–M3 from PLAN.md are done and in use. Visual affordance pass done
(toolbar, title strip, note labels, cursors, toasts). Ideas below are ordered by what Gabe
asked for first; nothing here is committed to a date.

## Next: Hub (session browser)
A window (menu bar → "Sessions…") that lists past captures grouped by day, then by session.
- Thumbnail of each annotated screen, mark count, notes preview, the instruction.
- Actions per session: copy prompt again, open folder in Finder, re-send to Claude/Ghostty,
  delete. Later: reopen a session to add screens or edit notes.
- Start simple (day → session → screens). Get fancier with search and filters later.

## Feedback types (capture "modes")
The same capture + marks pipeline, different packaging on send:
- **LLM feedback** (today): prompt.md with absolute PNG paths, pasted into Claude Code.
- **Website feedback**: also record browser name/version, URL, viewport, OS, user account
  from the frontmost browser tab; output a shareable page or Markdown for a human reviewer.
- **Pretty screenshot**: burn marks in, then frame the capture like macOS's ⌘⇧3 device
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
