#!/bin/bash
# Compile the production app code into an isolated native UI probe of the video editor.
# Usage: scripts/probe-video-editor.sh /path/to/existing-video.mp4 [--audio-merge] [--normal]
#        scripts/probe-video-editor.sh --build-only [--normal]   (compile only; touches no video)
# The video is copied next to the probe; the original is untouched. Drive it with
# PROBE_COMMANDS (see `probe(_:)` in VideoEditorWindowController.swift), e.g. `snapshot top`,
# `export-popover`. Only open and snapshot: do not run exports, presets or Save (no
# probe command exports any more, but ⌘S/⇧⌘S/⌘E key events and the popover buttons do).
# Capture, uploads and the menu bar are not started: the app delegate is replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
build_only=false
if [[ ${1:-} == --build-only ]]; then
  build_only=true
  shift
elif [[ $# -lt 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /absolute/path/to/existing-video.mp4 [--audio-merge] [--normal]" >&2
  echo "       $0 --build-only [--normal]" >&2
  exit 2
else
  probe_source="$1"
  shift
fi
probe_conditions=(-D OFFLINE -D VIDEO_EDITOR_PROBE)
probe_audio_merge=false
for option in "$@"; do
  case "$option" in
    --audio-merge) probe_audio_merge=true ;;
    --normal) probe_conditions=(-D MACSHOT_UI_PROBE -D VIDEO_EDITOR_PROBE) ;;
    *) echo "Unknown probe option: $option" >&2; exit 2 ;;
  esac
done
probe_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-source-editor-probe.XXXXXX")
probe_bundle="$probe_directory/SourceEditorProbe.app"
mkdir -p "$probe_bundle/Contents/MacOS"
if [[ $build_only == false ]]; then cp "$probe_source" "$probe_directory/input.mp4"; fi
cat > "$probe_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.macshot.source-editor-probe</string>
<key>CFBundleName</key><string>Source Editor Probe</string>
<key>CFBundleExecutable</key><string>SourceEditorProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
if [[ $probe_audio_merge == true ]]; then
  /usr/libexec/PlistBuddy -c 'Add :AudioMergeProbe bool true' "$probe_bundle/Contents/Info.plist"
fi
# Compile the whole macshot/ tree except main.swift, exactly like the macshotTests
# target does (a new source file never needs listing here). Only the two package
# modules the app imports are replaced with tiny stubs, since the probe has no
# Xcode package resolution: Sparkle (AppDelegate's updater) and WebP (ImageEncoder).
# The probe's @main (scripts/probe-video-editor.swift) supplies the entry point.
stubs="$probe_directory/stubs"
mkdir -p "$stubs"
cat > "$stubs/Sparkle.swift" <<'SWIFT'
import Foundation
public class SPUUpdater: NSObject {
    public var automaticallyDownloadsUpdates = false
    public var automaticallyChecksForUpdates = false
}
public protocol SPUUpdaterDelegate: NSObjectProtocol {
    func allowedChannels(for updater: SPUUpdater) -> Set<String>
}
public class SPUStandardUpdaterController: NSObject {
    public let updater = SPUUpdater()
    public init(startingUpdater: Bool, updaterDelegate: SPUUpdaterDelegate?, userDriverDelegate: AnyObject?) { super.init() }
    public func checkForUpdates(_ sender: Any?) {}
}
SWIFT
cat > "$stubs/WebP.swift" <<'SWIFT'
import AppKit
public struct WebPDecoderOptions { public init() {} }
public struct WebPDecoder {
    public init() {}
    public func decode(toNSImage data: Data, options: WebPDecoderOptions) throws -> NSImage { NSImage() }
}
public struct WebPEncoderConfig {
    public enum Preset { case picture }
    public static func preset(_ preset: Preset, quality: Float) -> WebPEncoderConfig { WebPEncoderConfig() }
}
public struct WebPEncoder {
    public init() {}
    public func encode(RGBA: UnsafePointer<UInt8>, config: WebPEncoderConfig, originWidth: Int, originHeight: Int, stride: Int) throws -> Data { Data() }
}
SWIFT
for module in Sparkle WebP; do
  swiftc -target "$(uname -m)-apple-macos12.3" -swift-version 5 -parse-as-library -module-name "$module" -emit-module -emit-module-path "$stubs/$module.swiftmodule" \
    -emit-object -o "$stubs/$module.o" "$stubs/$module.swift" > "$probe_directory/stub-$module.log" 2>&1 || {
      cat "$probe_directory/stub-$module.log" >&2
      exit 1
    }
done
sources=()
while IFS= read -r source_file; do sources+=("$source_file"); done < <(
  find macshot -name '*.swift' ! -name main.swift ! -path '*/.build/*' | LC_ALL=C sort)
# -Onone keeps the cold build of the whole tree short; PROBE_SWIFT_OPT=-O for realistic render speed.
swiftc "${PROBE_SWIFT_OPT:--Onone}" -target "$(uname -m)-apple-macos12.3" -swift-version 5 -default-isolation MainActor "${probe_conditions[@]}" -parse-as-library \
  -I "$stubs" "${sources[@]}" scripts/probe-video-editor.swift "$stubs/Sparkle.o" "$stubs/WebP.o" \
  -o "$probe_bundle/Contents/MacOS/SourceEditorProbe" > "$probe_directory/build.log" 2>&1 || {
    grep -E "error:" "$probe_directory/build.log" >&2 || cat "$probe_directory/build.log" >&2
    exit 1
  }
echo "Probe artifacts: $probe_directory"
if [[ $build_only == true ]]; then echo "Built $probe_bundle/Contents/MacOS/SourceEditorProbe (not run)"; exit 0; fi
echo "Saving in this editor replaces only: $probe_directory/input.mp4"
"$probe_bundle/Contents/MacOS/SourceEditorProbe" > "$probe_directory/runtime.log" 2>&1
