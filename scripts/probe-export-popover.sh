#!/bin/bash
# Visual probe for the export popover and the split Export button.
# Usage: scripts/probe-export-popover.sh [commands-file]
#
# Compiles the real ExportPopoverView, ExportPopoverModel, ExportSplitButton,
# ExportQueue and PopoverHelper from macshot/ into a small app with a fake top
# bar (scripts/probe-export-popover.swift). Commands (one per line, appended to
# the file while the probe runs) open the popover, toggle Adjust, hit-test,
# click controls with real events and write PNG snapshots to $PROBE_OUT.
#
# Safe by construction: no video file is read or written. The "renderer" only
# waits, so even a queued export never encodes, and nothing uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-export-popover-probe.XXXXXX")
sources=(
  macshot/Capture/CancellableRenderQueue.swift
  macshot/Capture/CaptionImport.swift
  macshot/Capture/CursorMotion.swift
  macshot/Capture/CursorTelemetry.swift
  macshot/Capture/EffectsVideoCompositor.swift
  macshot/Capture/EncoderSessionTracker.swift
  macshot/Capture/GIFEncoder.swift
  macshot/Capture/GIFExporter.swift
  macshot/Capture/KeystrokeTimeline.swift
  macshot/Capture/MediaExportPump.swift
  macshot/Capture/PreparedVideoSource.swift
  macshot/Capture/RecordingSessionStore.swift
  macshot/Capture/SafeNumerics.swift
  macshot/Capture/SampleBufferTiming.swift
  macshot/Capture/VideoAnnotationMotion.swift
  macshot/Capture/VideoAnnotationRasterizer.swift
  macshot/Capture/VideoCameraRecorder.swift
  macshot/Capture/VideoCompositionBuilder.swift
  macshot/Capture/VideoCompositionRendering.swift
  macshot/Capture/VideoEffectSnapshot.swift
  macshot/Capture/VideoEncoderPolicy.swift
  macshot/Capture/VideoEncodingSettings.swift
  macshot/Capture/VideoExportEncodingPlan.swift
  macshot/Capture/VideoExportJob.swift
  macshot/Capture/VideoFrameCadence.swift
  macshot/Capture/VideoRenderGeometry.swift
  macshot/Capture/VideoSceneBuilder.swift
  macshot/Capture/VideoSceneGeometry.swift
  macshot/Capture/VideoSceneRenderer.swift
  macshot/Capture/VideoTextRasterizer.swift
  macshot/Capture/VideoTranscoder.swift
  macshot/Model/Annotation.swift
  macshot/Model/AnnotationCodable.swift
  macshot/Model/LenientDecoding.swift
  macshot/Model/SavedCaptureValidation.swift
  macshot/Model/VideoAnnotationSegment+Style.swift
  macshot/Model/VideoAnnotationSegment.swift
  macshot/Model/VideoCensorSegment.swift
  macshot/Model/VideoCutSegment.swift
  macshot/Model/VideoFreezeSegment.swift
  macshot/Model/VideoKeyframes.swift
  macshot/Model/VideoOverlaySegment.swift
  macshot/Model/VideoProject.swift
  macshot/Model/VideoSpeedSegment.swift
  macshot/Model/VideoTextSegment.swift
  macshot/Model/VideoZoomSegment.swift
  macshot/Services/AtomicMediaSave.swift
  macshot/Services/BeautifyRenderer.swift
  macshot/Services/BuildVariant.swift
  macshot/Services/EditorCommandShortcutManager.swift
  macshot/Services/EditorExportCommand.swift
  macshot/Services/Export/ExportCloudflareSupport.swift
  macshot/Services/Export/ExportLocalDestination.swift
  macshot/Services/Export/ExportQueue.swift
  macshot/Services/Export/ExportRecords.swift
  macshot/Services/Export/ExportRemoteSync.swift
  macshot/Services/Export/ExportRun.swift
  macshot/Services/Export/ExportStages.swift
  macshot/Services/ExportPresetShortcutStore.swift
  macshot/Services/FilenameSanitizer.swift
  macshot/Services/KeyboardShortcutMatcher.swift
  macshot/Services/MediaExportCoordinator.swift
  macshot/Services/VideoSourceSnapshot.swift
  macshot/UI/Editor/Video/ExportPopoverModel.swift
  macshot/UI/Editor/Video/ExportPopoverView.swift
  macshot/UI/Editor/Video/ExportPreset.swift
  macshot/UI/Editor/Video/ExportPresetStore.swift
  macshot/UI/Editor/Video/ExportSplitButton.swift
  macshot/UI/Windows/ExportSettingsModel.swift
  macshot/UI/Windows/ExportSettingsTabView.swift
  macshot/UI/Editor/Video/VideoEditorDocument.swift
  macshot/UI/Editor/Video/VideoEditorExporter.swift
  macshot/UI/Editor/Video/VideoEditorStyle.swift
  macshot/Services/Export/FreeDestinationPicker.swift
  macshot/UI/Editor/Video/VideoRenderPlanner.swift
  macshot/UI/Popover/PopoverHelper.swift
  macshot/UI/Tools/OutlineTextRenderer.swift
)
swiftc -swift-version 5 -default-isolation MainActor -D OFFLINE -parse-as-library "${sources[@]}" scripts/probe-export-popover.swift \
  -o "$probe_directory/ExportPopoverProbe" > "$probe_directory/build.log" 2>&1 || {
    grep -E "error:" "$probe_directory/build.log" >&2 || cat "$probe_directory/build.log" >&2
    exit 1
  }
echo "Probe artifacts: $probe_directory"
export PROBE_OUT="${PROBE_OUT:-$probe_directory}"
if [[ $# -ge 1 ]]; then export PROBE_COMMANDS="$1"; fi
"$probe_directory/ExportPopoverProbe"
