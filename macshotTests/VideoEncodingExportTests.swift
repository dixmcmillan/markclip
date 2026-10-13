import AVFoundation
import AppKit
import XCTest

/// End-to-end checks for Phase 1 encoding: real files go through
/// `VideoEditorExporter` (the same entry the editor uses) and are decoded
/// back with `AVAssetReader`. No window server, no permissions.
@MainActor
final class VideoEncodingExportTests: XCTestCase {
    private var directory: URL!
    private let cleanup = DispatchQueue(label: "macshot.tests.encoding-cleanup")
    /// Documents own their source snapshot and must outlive the export.
    private var documents: [VideoEditorDocument] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Last, so tearDown always has a directory to remove.
        try MediaTests.require()
    }

    override func tearDownWithError() throws {
        documents.removeAll()
        cleanup.sync {}
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// Video-only H.264 MP4 with an exact frame rate. `noise` makes every frame
    /// incompressible so a bitrate target is actually the limiting factor.
    private func writeVideo(width: Int, height: Int, fps: Int32, frames: Int, noise: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoderPolicy.applying(to: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
        ]))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer),
                           kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
            let length = CVPixelBufferGetBytesPerRow(pixels) * height
            if noise {
                arc4random_buf(base, length)
            } else {
                memset(base, 0x80 + Int32(frame % 3), length)
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private func makeExporter(source: URL, configure: (VideoProject) -> Void = { _ in }) async throws -> VideoEditorExporter {
        let snapshot = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
            workspaceRoot: directory.appendingPathComponent("working"), cleanupQueue: cleanup)
        let prepared = try await PreparedVideoSource.load(snapshot)
        let document = VideoEditorDocument(prepared: prepared, asset: try XCTUnwrap(prepared.asset))
        configure(document.project)
        documents.append(document)
        return VideoEditorExporter(document: document)
    }

    @discardableResult
    private func export(_ exporter: VideoEditorExporter, _ settings: VideoExportSettings) async throws -> URL {
        let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let job = try exporter.mp4Job(settings, outputURL: output)
        try await job.export(to: output)
        return output
    }

    private func exportAndDecode(_ exporter: VideoEditorExporter, _ settings: VideoExportSettings) async throws -> Decoded {
        try decode(try await export(exporter, settings))
    }

    private func exportedCaptionPixels(_ exporter: VideoEditorExporter, _ settings: VideoExportSettings) async throws -> Int {
        try captionPixels(in: try await export(exporter, settings))
    }

    private struct Decoded {
        var codec: FourCharCode
        var size: CGSize
        var times: [Double]
        var audioTracks: Int
        var bytes: Int
        var duration: Double
        var frames: Int { times.count }
    }

    /// Decodes every video frame to BGRA, so a stream that merely carries the
    /// right codec tag but cannot be decoded fails here.
    private func decode(_ url: URL) throws -> Decoded {
        let asset = AVAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let format = try XCTUnwrap((track.formatDescriptions as? [CMFormatDescription])?.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertNotNil(sample.imageBuffer)
            times.append(sample.presentationTimeStamp.seconds)
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return Decoded(codec: CMFormatDescriptionGetMediaSubType(format), size: track.naturalSize, times: times,
                       audioTracks: asset.tracks(withMediaType: .audio).count, bytes: bytes,
                       duration: asset.duration.seconds)
    }

    /// Settings for a test export. Defaults to Medium quality so the export goes
    /// through `VideoTranscoder`, which honors `VideoEncoderPolicy` (software
    /// encoding in tests). The default quality, High H.264, would take the
    /// `AVAssetExportSession` route; tests that want it say so and call
    /// `HardwareEncoderTests.require()` first.
    private func settings(_ edit: (inout VideoExportSettings) -> Void = { _ in }) -> VideoExportSettings {
        var settings = VideoExportSettings()
        settings.quality = .medium
        edit(&settings)
        return settings
    }

    /// Settings as a preset resolves them at High quality, the default that
    /// leaves an unedited source untouched. Only for `needsRender` checks.
    private func highSettings(_ edit: (inout VideoExportSettings) -> Void = { _ in }) -> VideoExportSettings {
        var settings = VideoExportSettings()
        settings.quality = .high
        edit(&settings)
        return settings
    }

    /// True when these settings would encode through `AVAssetExportSession`.
    private func usesExportSession(_ settings: VideoExportSettings) -> Bool {
        settings.explicitBitrate == nil && settings.fpsCap == nil && settings.quality == .high && settings.codec == .h264
    }

    // MARK: HEVC

    func testArchivePresetWritesDecodableHEVCThroughTheTranscoder() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 640, height: 360))
        let exporter = try await makeExporter(source: source)
        let archive = try XCTUnwrap(ExportPresetStore.builtIns().first { $0.id == ExportPresetStore.archiveID })
        let resolved = archive.resolvedSettings(nativeSize: exporter.nativeCanvasSize)
        XCTAssertEqual(resolved.codec, .hevc)
        XCTAssertNil(resolved.explicitBitrate)
        XCTAssertNil(resolved.fpsCap)
        XCTAssertEqual(resolved.quality, .high)
        // Archive is HEVC + High + no bitrate: routed to VideoTranscoder, not a
        // HEVCHighestQuality session, so this encodes in software.
        XCTAssertFalse(usesExportSession(resolved))
        let output = try await export(exporter, resolved)
        let decoded = try decode(output)
        XCTAssertEqual(decoded.codec, kCMVideoCodecType_HEVC)
        XCTAssertEqual(decoded.frames, 60)
        XCTAssertEqual(decoded.size, CGSize(width: 640, height: 360))
        XCTAssertEqual(decoded.audioTracks, 2, "audio is kept")
    }

    func testHEVCThroughTheTranscoderFallbackDecodesAndRoundTripsAsASource() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 640, height: 360))
        let exporter = try await makeExporter(source: source)
        // An explicit bitrate cannot use an export-session preset.
        let output = try await export(exporter, settings { $0.codec = .hevc; $0.explicitBitrate = 3_000_000 })
        let decoded = try decode(output)
        XCTAssertEqual(decoded.codec, kCMVideoCodecType_HEVC)
        XCTAssertEqual(decoded.frames, 60)
        XCTAssertEqual(decoded.audioTracks, 2)

        // The HEVC result, reopened, is a valid source that needs no re-encode
        // for an HEVC preset but must be re-encoded for H.264.
        let reopened = try await makeExporter(source: output)
        XCTAssertFalse(reopened.needsRender(highSettings { $0.codec = .hevc }))
        XCTAssertTrue(reopened.needsRender(highSettings { $0.codec = .h264 }))
    }

    // MARK: Frame-rate cap

    func testSixtyFPSSourceIsCappedToThirtyAndNeverUpsampled() async throws {
        let source = try await writeVideo(width: 320, height: 180, fps: 60, frames: 90)
        let exporter = try await makeExporter(source: source)
        let uncapped = try await exportAndDecode(exporter, settings { $0.quality = .medium })
        XCTAssertEqual(uncapped.frames, 90, accuracy: 2, "the 60 fps cadence is preserved without a cap")

        let capped = try await exportAndDecode(exporter, settings { $0.fpsCap = 30 })
        XCTAssertEqual(capped.frames, 45, accuracy: 2)
        let steps = zip(capped.times.dropFirst(), capped.times).map { $0 - $1 }
        XCTAssertEqual(steps.reduce(0, +) / Double(steps.count), 1.0 / 30, accuracy: 0.002)
        XCTAssertEqual(capped.duration, 1.5, accuracy: 0.1, "dropping frames does not change the duration")

        // A cap above the source rate is not an upsample.
        let high = try await exportAndDecode(exporter, settings { $0.fpsCap = 120 })
        XCTAssertEqual(high.frames, 90, accuracy: 2)
    }

    func testThirtyFPSSourceWithAHigherCapStaysThirty() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let exporter = try await makeExporter(source: source)
        let decoded = try await exportAndDecode(exporter, settings { $0.fpsCap = 60 })
        XCTAssertEqual(decoded.frames, 60, accuracy: 1, "2 s at 30 fps, not 120 frames")
    }

    // MARK: Explicit bitrate

    func testStreamPresetHitsItsEightMegabitTarget() async throws {
        let source = try await writeVideo(width: 640, height: 360, fps: 30, frames: 90, noise: true)
        let exporter = try await makeExporter(source: source)
        let stream = try XCTUnwrap(ExportPresetStore.builtIns().first { $0.id == ExportPresetStore.streamID })
        let resolved = stream.resolvedSettings(nativeSize: exporter.nativeCanvasSize)
        XCTAssertEqual(resolved.explicitBitrate, 8_000_000)
        XCTAssertEqual(resolved.fpsCap, 30)
        let decoded = try await exportAndDecode(exporter, resolved)
        XCTAssertEqual(decoded.codec, kCMVideoCodecType_H264)
        XCTAssertEqual(decoded.frames, 90, accuracy: 2, "a 30 cap on a 30 fps source changes nothing")
        let bitrate = Double(decoded.bytes) * 8 / decoded.duration
        note("explicit 8 Mbps result: \(Int(bitrate)) bps")
        XCTAssertEqual(bitrate, 8_000_000, accuracy: 8_000_000 * 0.3)
    }

    // MARK: Mute

    func testMuteRemovesEveryAudioTrackOnEveryRoute() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 640, height: 360))
        let exporter = try await makeExporter(source: source)
        let control = try await exportAndDecode(exporter, settings())
        XCTAssertEqual(control.audioTracks, 2, "control: audio kept")
        let routes: [(String, (inout VideoExportSettings) -> Void)] = [
            ("H.264 session", { $0.quality = .high; $0.muted = true }),
            ("HEVC archive", { $0.quality = .high; $0.muted = true; $0.codec = .hevc }),
            ("transcoder", { $0.muted = true; $0.explicitBitrate = 4_000_000 }),
        ]
        for (name, edit) in routes {
            let routed = settings(edit)
            // The export-session iteration needs the hardware encoder.
            if usesExportSession(routed) && !HardwareEncoderTests.isEnabled { continue }
            let decoded = try await exportAndDecode(exporter, routed)
            XCTAssertEqual(decoded.audioTracks, 0, name)
            XCTAssertEqual(decoded.frames, 60, name)
        }
    }

    // MARK: Captions

    /// Pixels in the lower band that differ from the flat fixture color.
    private func captionPixels(in url: URL) throws -> Int {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 1), actualTime: nil)
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: image))
        let reference = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 10))
        var count = 0
        for y in stride(from: Int(Double(bitmap.pixelsHigh) * 0.7), to: Int(Double(bitmap.pixelsHigh) * 0.98), by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - reference.redComponent)
                    + abs(color.greenComponent - reference.greenComponent)
                    + abs(color.blueComponent - reference.blueComponent)
                if delta > 0.35 { count += 1 }
            }
        }
        return count
    }

    func testSoftAndOffCaptionsLeaveNoPixelsButBurnedCaptionsDo() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 640, height: 360))
        let exporter = try await makeExporter(source: source) {
            $0.captions = [VideoCaptionSegment(startTime: 0, endTime: 2, text: "BURNED CAPTIONS WORDS")]
        }
        let burned = try await exportedCaptionPixels(exporter, settings { $0.captions = .burned })
        XCTAssertGreaterThan(burned, 50, "burned captions draw into the pixels")
        for mode in [ExportCaptionsMode.soft, .off] {
            let pixels = try await exportedCaptionPixels(exporter, settings { $0.captions = mode })
            XCTAssertEqual(pixels, 0, "\(mode) captions must not be drawn")
        }
        // The same rule holds on the transcoder route and for HEVC.
        let softTranscoded = try await exportedCaptionPixels(exporter,
            settings { $0.captions = .soft; $0.explicitBitrate = 6_000_000 })
        let burnedTranscoded = try await exportedCaptionPixels(exporter,
            settings { $0.captions = .burned; $0.explicitBitrate = 6_000_000 })
        let softHEVC = try await exportedCaptionPixels(exporter, settings { $0.captions = .soft; $0.codec = .hevc })
        XCTAssertEqual(softTranscoded, 0)
        XCTAssertGreaterThan(burnedTranscoded, 50)
        XCTAssertEqual(softHEVC, 0)
        XCTAssertEqual(exporter.captionsVTT()?.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nBURNED"), true)
    }

    /// The High H.264 route is an `AVAssetExportSession` (no encoder-specification
    /// hook), so it only runs with MACSHOT_HARDWARE_ENCODER_TESTS=1 (CI).
    func testHighQualityExportSessionRouteHonorsSoftCaptionsAndMute() async throws {
        try HardwareEncoderTests.require()
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 640, height: 360))
        let exporter = try await makeExporter(source: source) {
            $0.captions = [VideoCaptionSegment(startTime: 0, endTime: 2, text: "BURNED CAPTIONS WORDS")]
        }
        let high = settings { $0.quality = .high; $0.captions = .soft; $0.muted = true }
        XCTAssertTrue(usesExportSession(high))
        let output = try await export(exporter, high)
        XCTAssertEqual(try decode(output).audioTracks, 0)
        XCTAssertEqual(try captionPixels(in: output), 0)
        let burned = try await exportedCaptionPixels(exporter, settings { $0.quality = .high; $0.captions = .burned })
        XCTAssertGreaterThan(burned, 50)
    }

    func testSoftCaptionsDoNotMutateTheEditorsProject() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        var project: VideoProject?
        let exporter = try await makeExporter(source: source) {
            $0.captions = [VideoCaptionSegment(startTime: 0, endTime: 1, text: "x")]
            project = $0
        }
        try await export(exporter, settings { $0.captions = .soft; $0.muted = true })
        XCTAssertEqual(project?.look.captions.show, true)
        XCTAssertEqual(project?.muted, false)
    }

    // MARK: VTT on the edited clock

    func testCaptionsVTTUsesTheSameEditedClockAsSRT() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let plain = try await makeExporter(source: source)
        XCTAssertNil(plain.captionsVTT(), "no captions: no sidecar")
        let exporter = try await makeExporter(source: source) {
            $0.trimStart = 0.5
            $0.captions = [VideoCaptionSegment(startTime: 1, endTime: 1.5, text: "Hi --> there")]
        }
        XCTAssertEqual(exporter.captionsVTT(), "WEBVTT\n\n00:00:00.500 --> 00:00:01.000\nHi --&gt; there\n")
        XCTAssertEqual(exporter.captionsSRT(), "1\n00:00:00,500 --> 00:00:01,000\nHi --> there\n")
    }

    // MARK: needsRender

    func testNeedsRenderMatrix() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let plain = try await makeExporter(source: source)
        XCTAssertFalse(plain.needsRender(highSettings()), "unedited H.264: copy the source")
        XCTAssertTrue(plain.needsRender(highSettings { $0.codec = .hevc }), "HEVC preset on an H.264 source re-encodes")
        XCTAssertTrue(plain.needsRender(highSettings { $0.format = .gif }))
        XCTAssertTrue(plain.needsRender(highSettings { $0.scale = 0.5 }))
        XCTAssertTrue(plain.needsRender(highSettings { $0.quality = .medium }))
        XCTAssertTrue(plain.needsRender(highSettings { $0.explicitBitrate = 8_000_000 }))
        XCTAssertTrue(plain.needsRender(highSettings { $0.fpsCap = 24 }), "a cap below the 30 fps source")
        XCTAssertFalse(plain.needsRender(highSettings { $0.fpsCap = 30 }), "a cap at the source rate is a no-op")
        XCTAssertFalse(plain.needsRender(highSettings { $0.fpsCap = 60 }))
        XCTAssertTrue(plain.needsRender(highSettings { $0.muted = true }), "the source has audio to strip")
        XCTAssertFalse(plain.needsRender(highSettings { $0.captions = .soft }))
        XCTAssertFalse(plain.needsRender(highSettings { $0.captions = .off }))

        let captioned = try await makeExporter(source: source) {
            $0.captions = [VideoCaptionSegment(startTime: 0, endTime: 1, text: "x")]
        }
        XCTAssertTrue(captioned.needsRender(highSettings { $0.captions = .burned }))
        XCTAssertFalse(captioned.needsRender(highSettings { $0.captions = .soft }), "captions alone are not a video edit")
        XCTAssertFalse(captioned.needsRender(highSettings { $0.captions = .off }))
        XCTAssertTrue(captioned.needsRender(highSettings { $0.captions = .soft; $0.codec = .hevc }))

        let trimmed = try await makeExporter(source: source) {
            $0.trimStart = 0.5
            $0.captions = [VideoCaptionSegment(startTime: 1, endTime: 1.5, text: "x")]
        }
        XCTAssertTrue(trimmed.needsRender(highSettings { $0.captions = .soft }), "other edits still render")

        let audioless = try await makeExporter(source: try await writeVideo(width: 64, height: 64, fps: 30, frames: 30))
        XCTAssertFalse(audioless.needsRender(highSettings { $0.muted = true }), "nothing to mute")
    }
}

private func note(_ message: String) { print("[VideoEncodingExportTests] \(message)") }
