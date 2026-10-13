# Kernel panic in the Apple Video Encoder IOMMU (dart-ave) during AVFoundation export tests

Draft for a Feedback Assistant report. Facts come from the panic report and the unified log on the affected Mac. Anything not directly observed is marked as an inference.

## Environment

- MacBook Pro, Apple M3 Pro (Mac15,6)
- macOS 27.0.1 (26A434)
- Xcode command-line build of a macOS app's unit-test bundle (`macshotTests.xctest`), with no host app
- Panic time: 2026-10-13 07:50 CDT

## What was running

Headless XCTest runs of a video-export test suite. The suite creates many short `AVAssetWriter` sessions (H.264 and HEVC, 64x64 to 640x360) and `AVAssetExportSession` exports (`AVAssetExportPresetHighestQuality` and `AVAssetExportPresetHEVCHighestQuality`). Runs went one at a time, serialized with a file lock.

Command, from the repository root:

```
xcodebuild -scheme macshotTests -configuration Debug -destination 'platform=macOS' \
  -resultBundlePath <tmp>/results.xcresult -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The suite was run 15 times in the hour before the panic. Each run produced about 30,000 lines of VideoToolbox encoder and decoder log. The tests in flight around the panic included new export tests on the `export-p1-encoding` branch, among them `testArchivePresetWritesDecodableHEVCThroughTheExportSession` (HEVC through `AVAssetExportSession`), plus the existing `AVAssetWriter` and `AVAssetExportSession` tests.

## Panic

```
panic(cpu 0 caller 0xfffffe004f1f1dcc): "dart-ave (0xfffffe2219d52000): DART(CPUDART) error:
SID 0 PTE invalid exception on write of DVA 0x10000d53180 ..." @AppleT8110DART.cpp:2265
```

The backtrace contains only Apple kernel frames (AppleT8110DART, IODARTFamily).

Panic file: `/Library/Logs/DiagnosticReports/Retired/panic-full-2026-10-13-075047.0002.panic`

## Unified log observations

**Test run 15 (xctest pid 67564)**
- 07:39:45: started a 640x360 H.264 hardware encoder session.
- 4 seconds later: exited cleanly.
- The AVE session received `AVE_Session_AVC_Stop` twice.

**Its encoder service (`VTEncoderXPCService`, pid 67568)**

It kept running for about 10 minutes after the test process exited. Once a minute until the panic it logged:

```
AVE ERR: AVE_FrameRecv::FrameDone encoding error -1004
H264FrameRec: DROPPING frame N
SampleBuffer err=-12731   (kCMSampleBufferError_RequiredParameterMissing)
```

**New test host (pid 70851)**

A new test host, with its own encoder service, started about 20 seconds before the panic. Its log lines never reached disk.

## Expected vs. actual

- **Expected:** when a client process exits, its hardware encoder session is torn down, and later sessions are unaffected. A misbehaving user-space client should never be able to panic the kernel.
- **Actual:** the orphaned session kept timing out frames in the hardware queue. Shortly after a new session started, the AVE wrote through the DART to an unmapped address and the system panicked.

**Inference (not verified):** the exited client's output buffers were unmapped while frames were still queued in the hardware. A new session restarted the AVE, which then wrote into the stale mapping.

## Reproduction (not yet attempted deliberately)

1. In one process, start an `AVAssetWriter` H.264 hardware session (640x360) and append a few frames.
2. Exit the process shortly after, or after a double stop: the log showed two `AVE_Session_AVC_Stop` calls.
3. Within a few minutes, start new hardware encoder sessions from new processes. Repeat the full test cycle as above.
4. Watch `log stream --predicate 'process == "VTEncoderXPCService"'` for `AVE ERR ... -1004` from a service whose client has exited.

## Mitigation in this project

- **Tests encode in software.** The `macshotTests` scheme and `scripts/run-tests.sh` set `MACSHOT_SOFTWARE_ENCODER=1`. `VideoEncoderPolicy` then adds `AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]` to every compressing `AVAssetWriterInput`. Sessions report `com.apple.videotoolbox.videoencoder.h264` and `com.apple.videotoolbox.videoencoder.hevc.vcp`. Users keep hardware encoding.
- **Hardware tests are opt-in.** Tests that need the hardware encoder (`AVAssetExportSession`, and assertions calibrated on hardware behavior) run only with `MACSHOT_HARDWARE_ENCODER_TESTS=1`, serially, and on their own.
- **Writers are never left mid-encode.** Writer teardown no longer calls `cancelWriting()` after `finishWriting` has started, or on a writer that is not `.writing`. Cancellation now waits for `finishWriting` to reach a terminal state.
- **Every test is checked.** After each test, the suite asserts that no tracked `AVAssetWriter` is still `.writing` and no export session is still exporting.
- **Run discipline:** no tight re-run loops. If `VTEncoderXPCService` logs `AVE ERR` or outlives its client by more than 30 seconds, reboot before running more hardware-encoder work.

After the mitigation:
- **No hardware encoder clients:** while the encoding test classes ran in software mode, sampling `ioreg -r -c AppleAVE2UserClient` every 0.2 s found no AVE user clients. 58 tests passed. `AVAssetWriter` still starts `VTEncoderXPCService`, which hosts the software encoder too.
- **Service exits cleanly:** no `VTEncoderXPCService` remained 30 seconds after each run.
- **Hardware tests pass:** the hardware-gated tests passed in one serial run after a reboot, and no encoder service remained afterwards.
- **Logs can't confirm either way:** on this machine the unified log did not persist `VTEncoderXPCService` messages during these runs, including the hardware run. A count of zero `AVE ERR` or `AVE_Session` lines is therefore not evidence.

## Second occurrence, same day (11:50 CDT)

Panic file: `/Library/Logs/DiagnosticReports/Retired/panic-full-2026-10-13-115041.0002.panic`

```
panic(cpu 1 caller 0xfffffe0037b05dcc): "dart-ave (0xfffffe25184f0000): DART(CPUDART) error: SID 0 PTE invalid
exception on write of DVA 0x10000d53240 (CTE 0x10 SEG 0 PTE 0x354) ERROR_STATUS 0x90000008 TIME 0 TTE 0 AXI_ID 0xc0"
@AppleT8110DART.cpp:2265
```

The panic was the same `dart-ave` PTE-invalid write as the first occurrence, at an almost identical device virtual address (`0x10000d53240` vs `0x10000d53180`). The backtrace again contained only AppleT8110DART and IODARTFamily frames.

**Observed timeline**
- **10:25:** boot.
- **10:26–10:27:** the hardware-gated tests ran once, serially, and finished without incident.
- **11:14–11:15:** the system slept and woke.
- **11:30:05:** a `VTEncoderXPCService` (pid 21017) started. Its client was not identified. It never had an `AppleAVE2UserClient` while it was sampled.
- **11:38–11:49:** one test run, in software-encoder mode only. It did heavy HEVC encoding through `AVAssetWriter` with `EnableHardwareAcceleratedVideoEncoder = false`. Export-session tests were skipped.
- **11:50:02:** panic, about 20–40 seconds after that run's test host exited.

**Running at the time (from the stackshot)**
- No `xctest` or `xcodebuild` process.
- Two `VTEncoderXPCService` instances: pids 21017 and 28149.
- The OBS virtual-camera system extension.
- `avconferenced` and `replayd`.
- `com.apple.photos.ImageConversionService`, with about 12,000 page-ins.

**The software encoders really are software.** `VTCopyVideoEncoderList` lists them as follows:
- `com.apple.videotoolbox.videoencoder.h264`: Apple H.264 (SW), `IsHardwareAccelerated` absent.
- `com.apple.videotoolbox.videoencoder.hevc.vcp`: Apple HEVC (SW), `IsHardwareAccelerated` absent.
- The hardware encoders are `…ave.avc` and `…ave.hevc`, with `IsHardwareAccelerated` true.

```swift
var list: CFArray?
VTCopyVideoEncoderList(nil, &list)   // lists encoders without creating a session
for e in list as! [[String: Any]] {
    print(e[kVTVideoEncoderList_EncoderID as String]!, e[kVTVideoEncoderList_IsHardwareAccelerated as String] ?? "nil")
}
```

**Inference (not verified):** both panics followed about a minute after a test host that did heavy encoding exited, which suggests encoder-service teardown is involved. In the second case, though, the test used only software encoders. Other clients of the encoder or media engine were also active: the OBS virtual camera, conferencing, screen capture and Photos conversions. So the trigger may not be limited to hardware sessions created by our process.

**Further mitigation:** all video-encoding test classes now run only on CI (`MACSHOT_MEDIA_TESTS=1`), never on this Mac.
