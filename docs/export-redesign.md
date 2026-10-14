# Export redesign

Status: spec agreed 2026-10-13; Phases 0-6 implemented (Phase 5 UI: split button, `ExportPopoverView`, preset shortcuts, Settings ▸ Export and Cloudflare tabs, toasts; Phase 6: the old `VideoExportPanel` path and its loose UserDefaults keys are gone). Phase 7 (legacy uploaders) is separate. The old popover was broken (blank Preset popup, MP4/GIF control unresponsive) and never got a stopgap fix.

## Why

Two real use cases: a local archive copy, and an upload to Cloudflare Stream (or Images for short loops) that training software picks up automatically. Copying to the clipboard is not a use case. The old popover asked four questions (preset, format, resolution, frame rate) before any action; the redesign makes one keypress do the whole job.

## Spec

### Entry points

- Top bar: a split **Export** button. The main part runs the last-used preset; the chevron opens the export popover. The top-bar **Copy** button is removed.
- ⌘E opens the popover. ⌘S and ⇧⌘E run the last-used preset (same as the main segment). ⇧⌘S is Save As…: it asks where to put one export of the open popover's selected preset (with its Adjust overrides), else the last-used preset.
- Per-preset shortcuts, editor-scoped, customizable; defaults ⌃⌘1–⌃⌘4 by preset order. Also listed under File ▸ Export Preset.

### Presets

A preset is encoding plus destination. Built-ins:

| Preset | Encoding | Destination | Captions | Audio |
|---|---|---|---|---|
| Archive (⌃⌘1) | HEVC, source resolution, High; source copied directly when unedited | `~/Movies/Markclip Archive` | Burned in | Keep |
| Stream (⌃⌘2) | H.264, long edge ≤1920, ≤30 fps, ~8 Mbps | Cloudflare Stream; "also save locally" on | WebVTT soft track; `.vtt` sidecar beside the local copy | Keep |
| Loop (⌃⌘3) | GIF, auto-fit to Cloudflare Images limits | Cloudflare Images | Burned in | n/a |

Preset fields:
- Format: H.264, HEVC or GIF.
- Size cap: long edge, or source resolution.
- Frame rate cap.
- Quality tier, or an explicit bitrate.
- Audio: keep or mute.
- Captions: burned in, soft track or off.
- Destination: folder, Stream or Images.
- Also save locally (Stream and Images only).
- Require signed URLs (Stream only).
- Shortcut.

Animated WebP is deferred. Revisit after checking how Images delivers an uploaded GIF.

### GIF auto-fit (Loop)

Cloudflare Images caps a file at 10 MB, and caps an animation's area summed across all frames. The docs give both 50 MP and 100 MP; target 50 MP.

Auto-fit reduces settings in this order until the result fits:
1. fps: 15 → 12 → 10 → 8
2. Long edge, down to 640 px

The popover reports what changed, e.g. "fit: 12 fps, 960 px". If 8 fps at 640 px still doesn't fit, auto-fit refuses and suggests the Stream preset instead.

### Popover

- Preset list, with each preset's shortcut shown.
- Summary and size estimate for the selected preset.
- **Adjust** disclosure for one-off overrides, plus **Save as Preset…**.
- **Save As…**, which picks a location.
- An upload status line for this project, e.g. "Uploaded 2d ago · processing / ready · Open in dashboard · Retry".
- While exporting: progress and Cancel.

Full preset editing lives in a new Settings ▸ Export tab.

### Uploads (Cloudflare only)

- **Account:** one Cloudflare account. The account ID and API token (Stream Edit and Images Edit permissions) are stored in Keychain. Settings has a Test connection button.
- **Stream upload:** always resumable (tus), so a large archive-quality upload survives a network drop within a session. Nothing is persisted across app restarts.
  - Metadata is the name only (the project name), plus the preset's signed-URL setting.
  - Captions upload as a WebVTT track per language once the video exists.
- **Images upload:** multipart POST.
- **Completion:**
  - A toast when the upload finishes.
  - The popover shows processing status until Stream reports the video ready.
  - Failed uploads stay in the status line with Retry.
- **Re-upload:** Stream can't replace a video in place. A re-upload creates a new UID, then deletes the previous UID once the new one is ready. (No documented in-place replace; assumption.)
- **Removed entirely:** Google Drive, S3 and imgbb, for both video and screenshot uploads (decided 2026-10-13: screenshot upload isn't part of this workflow). Cloudflare is the only upload provider, and it is used for video export only.
- **No system notifications.** Jobs are single and usually under a minute, so the existing toasts are enough.

### Local files

- Files are named after the project.
- Re-exporting with the same preset overwrites the file that preset last wrote for this project. It overwrites only when the file on disk is still the one the app wrote; otherwise it falls back to numbering (`Name 2.mp4`).

### Progress and concurrency

- A progress ring on the Export button replaces the separate progress window.
- Jobs run one at a time. Triggering a second preset mid-export queues it.
- A job is render → publish locally → upload → captions → poll. Cancel stops whichever stage is running.

### Unchanged / out of scope

- The "after recording → clipboard" setting.
- Markup is always burned in.
- The OFFLINE build stays: it hides Stream/Images destinations and the Cloudflare settings, so only folder presets remain.
- Deferred:
  - Loudness normalization (belongs in the editor)
  - Direct training-software API integration
  - Cloudflare AI captions
  - Custom Stream `meta`
  - 1440p Stream preset, if 1080p text proves hard to read

## Current code (facts the plan relies on)

Paths are relative to `macshot/`.

**Settings and presets**
- `VideoExportSettings` (`UI/Editor/Video/VideoEditorExporter.swift:4`) is a non-Codable struct, persisted as loose keys:
  - `lastExportScale`
  - `lastExportQuality`
  - `gifExportFPS`
  - `videoEditorExportFormat`
  - `lastExportDestinationDirectory`
- `VideoExportPreset` (`UI/Editor/Video/VideoExportPresets.swift:9`) is lenient Codable, stored under `videoExportCustomPresets`.
- The job builder is the private `export(to:directory:quickExport:)` in `UI/Editor/VideoEditorWindowController+Export.swift` (~:88-145). `startExport` (~:317) is the lifecycle wrapper.

**Encoding**
- HEVC already exists at the encoding layer: `VideoCodec {h264, hevc}` and `outputSettings` in `Capture/VideoEncodingSettings.swift:53`.
- `VideoExportEncodingPlan` (`Capture/VideoExportEncodingPlan.swift`) hardcodes `.h264` and has no fps cap or bitrate override.
- High quality always goes through `AVAssetExportSession` (`AVAssetExportPresetHighestQuality`), which has no bitrate or fps knobs.
- The composition `frameDuration` is settable through `prepare(frameDuration:)` (`VideoEditorExporter.swift:92`).

**GIF**
- `GIFExporter.Request` has no knobs. fps comes from the composition `frameDuration`, and scale from the render settings.
- `GIFEncoder` writes as it goes, but exposes no byte count and has no size estimate.

**Captions**
- `VideoCaptionSegment` (`Model/VideoProject.swift:294`) is the caption model. Burn-in is gated by `look.captions.show` (`Capture/VideoSceneRenderer.swift:368`).
- SRT already exists (`captionsSRT()`, `VideoEditorExporter.swift:188`; `CaptionTimeline.srt`). There is no VTT writer.
- `hasEdits` counts captions.

**Project persistence**
- `VideoProject` has no project UUID.
- `encoded()` feeds undo snapshots and dirty comparison, so new export metadata inside the project would pollute undo.

**Export jobs**
- `MediaExportCoordinator` has no queue. The editor rejects a second export via `isExporting`.
- `FreeDestinationPicker` already supports a `keep:` URL for overwriting a prior output.
- `AtomicMediaSave.commit(overwritingExisting:)` is the atomic publish.

**Upload plumbing and settings**
- `PreparedUploadBody` and `UploadTransport` provide streamed `upload(fromFile:)` with progress. There are no resumable uploads yet.
- `KeychainSecretStore` (`Services/SecretStore.swift`) exists; today it is used only for the caption API key.
- `OFFLINE` is passed as a command-line compilation condition by `scripts/run-tests.sh`, the probe scripts and CI. Upload and cloud code must be wrapped in `#if !OFFLINE` (`CLAUDE.md`).

**UI and shortcuts**
- `EditorCommandShortcutManager.Shortcut` is Codable (character plus modifiers). Its `Action` enum is fixed, so per-preset shortcuts need a keyed store.
- The Settings recorder (`SettingsWindowController.swift:1486-1520`) requires ⌘.
- Nothing is bound to ⌃⌘1–4 today.
- `PopoverHelper` sets `contentSize` once and has no resize API. The old panel's fixed 300 pt frame plus a one-time `fittingSize` is the likely cause of the dead controls.

## Plan

Phases 1–3 are independent once Phase 0 lands and can run in parallel. Phase 4 joins them, Phase 5 is the UI, and Phase 6 deletes the old path. Every phase ends green on the normal and OFFLINE suites.

### Phase 0: preset model and resolved settings

- **New `ExportPreset` model.** Lenient Codable, using `decode(_:or:)`, with the fields listed under Presets. It replaces `VideoExportPreset`.
  - Destination is an enum: `.folder(bookmark)`, `.stream`, `.images`.
  - `.stream` and `.images` are unavailable under OFFLINE, and such presets are hidden there.
- **New `ExportPresetStore`.**
  - Stores presets under a new key, `exportPresets.v2`, plus `lastUsedExportPresetID`.
  - Seeds the three built-ins.
  - Migrates the old `videoExportCustomPresets` once: old MP4 → H.264 folder preset, old GIF → GIF folder preset.
  - Old loose keys are read once to seed the folder for the Archive preset, if `lastExportDestinationDirectory` is set. Otherwise the folder defaults to `~/Movies/Markclip Archive`.
- **Extend `VideoExportSettings` into the resolved, per-run value.** New fields: `codec`, `fpsCap`, `explicitBitrate`, `captions`, `muted`, `gifFit`. It is built from a preset plus the Adjust overrides, and no longer persisted on its own.
- **Tests:**
  - Rewrite `ExportPresetTests`: built-ins, migration, lenient decode of a partial or unknown preset, OFFLINE hiding.
  - Add fixtures to `LegacyDecodingTests`.

### Phase 1: encoding (HEVC, fps cap, bitrate, captions, mute)

- **`VideoExportEncodingPlan.make(...)`** takes `codec`, `fpsCap` and `explicitBitrate`.
  - `outputSettings` uses `plan.codec`.
  - The fps cap also sets the composition `frameDuration`.
  - Size estimates stay H.264-only, per `CLAUDE.md`.
- **Routing:**
  - Any explicit bitrate or fps cap goes through `VideoTranscoder`, whatever the quality tier.
  - Archive (HEVC, High, no bitrate) goes through `VideoTranscoder` with HEVC at the High bits-per-pixel budget, not `AVAssetExportPresetHEVCHighestQuality`. A session ignores `VideoEncoderPolicy` and can only be tested on the hardware encoder, which the suite must not drive (`docs/feedback/2026-10-13-ave-dart-panic.md`). Only H.264 + High + no bitrate/cap still uses the `HighestQuality` session.
  - The direct source copy remains only when nothing is edited and the preset is H.264/HEVC-compatible with the source.
  - `needsRender` must treat "captions soft or off on a project with captions" as unedited video, so it can't rely on `hasEdits` alone.
- **Captions mode:** for soft or off, `prepare()` sets `look.captions.show = false` on its project copy.
- **VTT:** add `CaptionTimeline.vtt` next to `.srt`, mapped onto the edited clock exactly like `captionsSRT()`.
- **Mute:** set `muted` on the prepared copy.
- **Tests:**
  - Plan tests: HEVC settings, fps cap, explicit bitrate.
  - A `VideoTranscoderTests` case: an HEVC output decodes, and a 30 fps cap is respected on a 60 fps source.
  - VTT golden-string tests that mirror the SRT ones.
  - An export with soft captions has no burned caption pixels (`ImageProbe`).

### Phase 2: GIF auto-fit

- **`GIFFitPlanner`** is pure.
  - **Inputs:** duration, source size, budget (10 MB, 50 MP total area), and floors (640 px, 8 fps).
  - **Output:** an ordered ladder of (fps, long edge) rungs.
  - **Area:** checked analytically before encoding (frames × width × height). Use the nominal frame count, not post-merge holds, as the conservative bound.
- **Byte budget:**
  - `GIFEncoder` exposes a running byte count.
  - `GIFExporter` gets an optional byte limit and aborts early with a distinct "over budget" error.
  - The fit job re-runs on the next rung. Every attempt goes to staging; only the winning attempt is published.
- **No rung fits:** the job fails with a "too long for Images, use Stream" error that the popover renders.
- **Tests:**
  - Planner ladder and floor tests.
  - An exporter abort test: no partial output gets published.
  - A fit integration test on a short synthetic clip with a deliberately tiny budget.

### Phase 3: Cloudflare client (`#if !OFFLINE`)

- **`CloudflareAccount`:**
  - Stores the account ID and API token in `KeychainSecretStore`, never in UserDefaults.
  - Confirm the `SettingsPortability` secret filter can never export the token.
  - `testConnection()` checks the token verify endpoint plus a Stream list call.
- **`CloudflareStreamClient`:**
  - **tus upload:**
    - Create with `Upload-Length` and `Upload-Metadata` (`name`, `requiresignedurls`).
    - Read the UID from the `stream-media-id` response header.
    - PATCH 50 MiB chunks (each a multiple of 256 KiB) through the existing `UploadTransport` progress plumbing.
    - On failure, HEAD to get the offset and resume, a bounded number of retries.
  - **`status(uid)`:** returns `readyToStream`, `status.state` and `pctComplete`.
  - **`delete(uid)`.**
  - **`putCaptions(uid, lang, vtt)`.**
- **`CloudflareImagesClient`:** a streamed multipart POST to `images/v1`, reusing `PreparedUploadBody`.
- **Tests:** `URLProtocol` stubs, modeled on `UploadRequestTests`, covering:
  - request shape and headers
  - chunk sizes and alignment
  - resume after a stubbed mid-upload failure
  - reading the UID from the header
  - error mapping
- Nothing in the suite hits the network.

### Phase 4: export run, queue, per-project memory

- **Export records sidecar.** `<take>.exports.json`, written beside `<take>.project.json` through the same document folder logic. It is deliberately kept out of `VideoProject`, so it doesn't enter undo snapshots or dirty state.
  - Contents: per preset id, the last local file (path, size, mtime), Stream UID or Images ID, upload date, state (uploading, processing, ready, failed), and `pendingDeleteUID`.
  - Lenient Codable.
- **`ExportRun`** carries out one preset.
  1. **Render** to staging.
  2. **Publish locally** via `AtomicMediaSave`. Overwrite only if the recorded file still matches (path, size, mtime); otherwise use `FreeDestinationPicker` numbering. Write the `.vtt` sidecar if the preset uses a soft track.
  3. **Upload.**
  4. **Captions** (Stream).
  5. **Record.**
  6. **Poll** Stream status every few seconds while the app runs. Once the video is ready, delete the previous UID and clear `pendingDeleteUID`.
  - Uploads-only presets with "also save locally" off upload from the staging file and then discard it.
  - Registers with `MediaExportCoordinator`. Holds input leases until the worker completes. Calls `beginPublication` before the local publish.
- **`ExportQueue`** (per editor) runs jobs serially. Triggering a preset while busy enqueues it. Cancel stops the current stage and can drop queued jobs. It replaces the `isExporting` rejection.
- **On popover open:** refresh any record still processing, and retry a pending delete of an old UID.
- **Tests:**
  - Records round-trip and lenient decode.
  - The overwrite guard (matching vs. replaced file).
  - Queue ordering and cancel at each stage, with stubbed stages.
  - The old UID is deleted only after ready.

### Phase 5: UI

- **Top bar** (`UI/Editor/Video/VideoEditorChrome.swift`):
  - Replace the Export and Copy pills with a split control: main segment plus chevron, with a progress ring overlay drawn in the pill.
  - Remove Copy and its ⌘C video-export binding. Keep ⌘C for whatever the editor uses it for otherwise; check `handleKeyEquivalent`.
- **`ExportPopoverView`** replaces `VideoExportPanel`.
  - Fully Auto Layout. No fixed frame.
  - When the Adjust disclosure or the status line changes, update the popover's `contentSize`. This needs a small `PopoverHelper.resizeActive(to:)` addition.
  - Hit-testing is verified with `scripts/probe-video-editor.sh`, since that is how the old popover broke.
- **Shortcuts:**
  - New `ExportPresetShortcutStore`, keyed by preset id, reusing the `Shortcut` value type.
  - `handleKeyEquivalent` matches preset shortcuts through `KeyboardShortcutMatcher`, never raw key codes (per `CLAUDE.md`).
  - File ▸ Export Preset submenu shows the key equivalents.
  - ⇧⌘E runs `lastUsedExportPresetID`.
- **Settings ▸ Export tab**:
  - Wiring: add a `tabDefs` entry and register the tab in both `tabContentViews` places in `SettingsWindowController.swift`.
  - Contents: preset list, editor, folder picker, and shortcut recorder. The recorder is adapted to accept ⌃⌘ without ⌘-only validation.
- **Cloudflare account** section: lives in the existing Uploads tab, which is already OFFLINE-gated.
- **Toasts:** "Saved", "Uploaded to Stream" and "Ready" use the existing toast (`AppDelegate.showExportNoticeToast` / `UploadToastController`). No system notifications.
- **Localization:** existing translations are kept, but new strings need only an English entry; other locales fall back to English at runtime (see `CLAUDE.md`).

### Phase 6: removal and cleanup

Done. What changed relative to the list below: the editor's `prepare` step keeps `MediaExportProgressController` (it shows progress and Cancel while a large video is copied in, which is not an export); `FreeDestinationPicker` stays (now `Services/Export/FreeDestinationPicker.swift`, used by `ExportLocalDestination`); `VideoExportSettings` is a pure per-run value; the loose keys are deleted by `ExportPresetStore` right after the migration has read them (flag `exportPresets.v2.legacyKeysRemoved`, also covering users who migrated earlier). The Esc-cancels-export binding went with the legacy job; cancel is in the popover. The video Copy-to-clipboard action and the legacy panel's Show in Finder button are gone (the completion toast has Show in Finder). `ExportEnvironment.localFilePublished` carries over the legacy `VideoSourceSnapshot.didSave` call so saving over a disposable input keeps that file.

Delete:
- `VideoExportPanel`
- the video `copyAction`, `copyGIFData` and `copyMP4Data`
- the video `uploadAction` (Drive/S3)
- `MediaExportProgressController` usage from the editor (keep it if other callers remain)
- the old loose export keys, after migration
- `VideoExportPreset`, `QuickExportDestination` and `QuickExportFilename`, if nothing else uses them

### Phase 7: remove legacy uploaders (Drive, S3, imgbb)

Independent of Phases 1–5. Can land any time after Phase 6, or before the Cloudflare work to clear the way. Keep the provider-neutral plumbing that Cloudflare reuses: `UploadPayload`, `PreparedUploadBody`/`UploadTransport`, `UploadJob` (quit drain) and `UploadToastController`.

**Delete**
- `Upload/GoogleDriveUploader.swift`, `Upload/S3Uploader.swift` and `Upload/ImgbbUploader.swift`.
- Screenshot upload end to end:
  - `AppDelegate.uploadImage` and `showUploadProgress` (`AppDelegate.swift:~2318-2430`), plus the upload toast wiring used only by them.
  - The overlay upload action, its confirm alert and the `uploadConfirmEnabled` setting (`OverlayView.swift:~8246`, `OverlayView+Popovers.swift`).
  - Upload in `DetachedEditorWindowController.swift:~549` and `HistoryOverlayController.swift:~254`.
  - Any upload toolbar button or upload shortcut. Saved `enabledTools` values naming the removed action must decode leniently and be dropped, not crash.
- The Google OAuth URL scheme in `Info.plist` (`CFBundleURLTypes`).

**Update**
- **Settings ▸ Uploads tab:** strip the provider popup, Drive and S3 fields. What remains is the Cloudflare account section, so rename the tab to "Cloudflare" (still `#if !OFFLINE`).
- **`SettingsPortability`:** drop the Drive, imgbb and S3 key entries. The Cloudflare token is never in UserDefaults, so it can't be exported.
- **One-time cleanup on launch:** delete stale credentials.
  - UserDefaults: `s3SecretAccessKey` (a plain-text secret), S3 access key, bucket and endpoint keys, `imgbbAPIKey`, `imgbbUploads`, `uploadProvider`, `googleDriveRefreshToken`, `gdriveUserEmail`, `gdriveFolderName` and `uploadConfirmEnabled`.
  - The Drive token file under Application Support.
  - Get the exact key list from the uploaders before deleting them.
- **`.github/workflows/build-release.yml:~153-162`:** the offline build strips and then asserts the Google OAuth URL scheme. The normal build will no longer contain it either, so the strip step becomes a no-op. Keep the assertion, so the scheme can't come back, or delete both.
- **Tests:**
  - Delete the Drive, S3 and imgbb cases in `UploadRequestTests` and `UploadAndClipboardTests`. Keep the payload and transport cases.
  - Update `SettingsPortabilityTests`.
  - Fix `scripts/probe-video-editor.swift` references.
- **Docs:** `README.md` and `PRIVACY.md` (no more Drive, S3 or imgbb, and Cloudflare is now the upload service). Comments in `SecretStore.swift` and `SandboxContainerMigration.swift`.
- **Localization:** remove orphaned upload strings from all locale tables. About 40 `.strings` files mention imgbb or Google Drive.

### Docs follow-up

Update `ROADMAP.md` (export line) and `CLAUDE.md`:
- The Upload/ file list, Output Actions, Persistence `Upload:` line, and the `GoogleDriveUploader` mention in Project Setup's hardcoded-folder note.
- Export rules: HEVC estimate rule, Cloudflare upload rules, sidecar records.
- Persistence (UserDefaults) section: new preset and shortcut keys, removed export keys.
- Popover rule: dark appearance, verified in both system appearances.

## Verification

- **Per phase:**
  - `scripts/run-tests.sh` and `scripts/run-tests.sh --offline`.
  - The Release build for strict concurrency: `xcodebuild -scheme macshot -configuration Release build 2>&1 | grep "error:"`, both normal and OFFLINE.
- **UI:**
  - `scripts/probe-video-editor.sh` popover probes: every control receives clicks, and the popover resizes when Adjust is toggled.
  - Manual pass of the split button, the shortcuts, and the progress ring.
- **End-to-end Cloudflare check.** Needs a real account ID and API token from the user; the suite never touches the network.
  - Stream preset on a clip over 200 MB (tus path).
  - Soft captions visible in the Stream player.
  - Re-upload deletes the old UID after the new one is ready.
  - Loop preset lands in Images under 10 MB.
  - Check whether Images serves the GIF as animated WebP. This decides the WebP follow-up.
