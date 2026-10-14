# Roadmap

This fork is becoming its own app: a lightweight, personal video editor for
marking up training videos — a "mini Premiere/Resolve" tailored to one
workflow. It started from macshot's Studio editor and stays GPL-3.0.

Working name: **TBD** (see "Identity"). Living document — add ideas under
"Inbox" and move them into a phase when they're scheduled.

## Direction

- Video editing first. Keep screen recording (for recording your own
  training videos); hide the screenshot flow now and remove it over time.
- Standalone: no upstream PRs. Keep the `upstream` remote only to
  cherry-pick fixes worth having (recording, export); stop wholesale merges.
- GPL-3.0 stays: credit macshot in the README and About box; source stays
  public if builds are ever shared.

## Done

- Pause-and-annotate: timed drawings made with the full screenshot toolkit.
- Entrance/exit animations (draw-on, pop, slide, wipe, fade) with stagger.
- Overlay clips with alpha (ProRes 4444, HEVC with alpha, stills).
- Move, scale and rotate drawings and overlays on the preview.
- Keyframed position, scale, rotation and opacity with easing.

## Phase 1 — Identity

- New name, bundle ID and icon; drop macshot branding (keep credits).
- Regular Dock app: launch opens a Welcome / Recent Projects window.
- Register video document types so Finder "Open With", drag onto the Dock
  icon and launchers (Raycast, Spotlight) open videos directly.
- File menu: Open, Open Recent, Save, Save As…, Export; menu bar icon optional (off by
  default).
- Hide the screenshot capture flow; keep screen recording.
- README/About rewritten for the new app; stop wholesale upstream merges.

## Phase 2 — Quick wins

- Playback: full J/K/L shuttle (repeat L for 2×/4×, J for reverse, K
  pause) and a playback speed menu.
- Export: done — split Export button running the last-used preset (⌘S / ⇧⌘E), ⌘E popover, ⇧⌘S Save As…, saved presets with per-preset shortcuts, Cloudflare Stream/Images upload (see docs/export-redesign.md; legacy export panel removed).
- Transcription: Apple's macOS 26 SpeechAnalyzer instead of the old
  SFSpeechRecognizer; import SRT/VTT captions (e.g. from MacWhisper);
  optional cloud providers with your own API key.

## Phase 3 — Timeline v2

- Generic multi-track timeline: user-ordered tracks with z-order for
  video, overlays/annotations and audio, replacing the fixed per-type lanes.
- Layer multiple annotations on separate tracks.

## Phase 4 — Built on the new timeline

- Voiceover tracks: record narration in the editor, ducking, levels.
- Multiple clips / B-roll in one project.
- Editable templates: callout box with pointer, circle + label, lower
  third, step counter — text and color edited in the app.

## Ongoing

- Remove screenshot-only code as it gets in the way.
- Drag-and-drop media onto the editor; let overlays extend past the frame.

## Inbox

- (new ideas go here)
