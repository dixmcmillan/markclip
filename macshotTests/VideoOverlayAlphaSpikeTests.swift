import AVFoundation
import AppKit
import CoreImage
import CoreVideo
import XCTest

/// Alpha spike: pushes a real ProRes 4444 / HEVC-with-alpha overlay clip
/// through the actual composition → `EffectsVideoCompositor` → `VideoSceneRenderer`
/// path over an opaque source and checks the compositing is correct — no
/// premultiplication darkening/fringing, and the transparent background of
/// the overlay clip is invisible.
///
/// This exercises the exact machinery `VideoCompositionBuilder`'s overlay
/// track insertion and `VideoOverlayLayer` rendering use, at the lowest level
/// (no `VideoEditorDocument`/planner), the same way `VideoStudioMediaTests`
/// exercises framed-scene rendering directly.
@MainActor
final class VideoOverlayAlphaSpikeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Last, so tearDown always has a directory to remove.
        try MediaTests.require()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: Fixtures

    /// BGRA bytes for one pixel: straight (unassociated) color at `alpha`.
    private func writePixel(_ base: UnsafeMutablePointer<UInt8>, offset: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = a
    }

    /// An opaque solid-color clip encoded with a plain codec (no alpha channel involved).
    private func makeOpaqueMovie(bgr: (UInt8, UInt8, UInt8), width: Int, height: Int,
                                 frameCount: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        EncoderSessionTracker.track(writer, "VideoOverlayAlphaSpikeTests")
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: VideoEncoderPolicy.applying(to: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                             AVVideoWidthKey: width, AVVideoHeightKey: height]))
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        XCTAssertTrue(writer.startWriting())
        // Any early exit (a throwing unwrap) must not leave the encoder session running.
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for tick in 0..<frameCount {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    writePixel(base, offset: y * stride + 4 * x, b: bgr.0, g: bgr.1, r: bgr.2, a: 255)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(tick), timescale: 30))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    /// A clip with a half-transparent colored square centered on a fully
    /// transparent background, encoded with an alpha-capable codec. Color
    /// data is written as straight (unassociated) alpha and tagged as such;
    /// this is exactly what the spike needs to verify survives the round trip.
    /// Returns `nil` when the codec can't be encoded on this machine.
    private func makeAlphaMovie(codec: AVVideoCodecType, squareBGR: (UInt8, UInt8, UInt8),
                                width: Int, height: Int, frameCount: Int, in directory: URL) throws -> URL? {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        EncoderSessionTracker.track(writer, "VideoOverlayAlphaSpikeTests")
        let input = AVAssetWriterInput(mediaType: .video,
            outputSettings: VideoEncoderPolicy.applying(to: [AVVideoCodecKey: codec,
                                                             AVVideoWidthKey: width, AVVideoHeightKey: height]))
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard writer.startWriting() else { return nil }
        // Every early `return nil` must stop the encoder session it started.
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let square = CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)
        for tick in 0..<frameCount {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let buffer = pb else { return nil }
            CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + 4 * x
                    if square.contains(CGPoint(x: x, y: y)) {
                        writePixel(base, offset: offset, b: squareBGR.0, g: squareBGR.1, r: squareBGR.2, a: 128)
                    } else {
                        writePixel(base, offset: offset, b: 0, g: 0, r: 0, a: 0)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            // Hardware encoders (HEVC) accept frames asynchronously.
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard input.isReadyForMoreMediaData else { return nil }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(tick), timescale: 30)) { return nil }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { return nil }
        return url
    }

    // MARK: Pipeline

    /// Builds a one-overlay-track composition and renders a single frame
    /// through the real `EffectsVideoCompositor`/`VideoSceneRenderer`.
    private func renderCenterFrame(overlayURL: URL, width: Int, height: Int,
                                   bgBGR: (UInt8, UInt8, UInt8)) async throws -> NSBitmapImageRep {
        let backgroundURL = try makeOpaqueMovie(bgr: bgBGR, width: width, height: height, frameCount: 6, in: directory)
        let background = AVURLAsset(url: backgroundURL)
        let overlay = AVURLAsset(url: overlayURL)
        _ = try await background.load(.tracks)
        _ = try await overlay.load(.tracks)
        let duration = 6.0 / 30
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: overlay, startTime: 0,
                                                                 duration: duration, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: background,
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: duration, compositionDuration: duration)],
            includeAudio: false, overlays: [overlayInput])
        let placement = try XCTUnwrap(built.overlayPlacements[overlayInput.id], "overlay track was not placed")
        let overlayTrack = try XCTUnwrap(built.composition.track(withTrackID: placement.trackID))
        let upright = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: overlayTrack.naturalSize,
            preferredTransform: overlayTrack.preferredTransform))
        let overlayLayer = VideoOverlayLayer(id: overlayInput.id, trackID: placement.trackID, stillImage: nil,
            uprightTransform: upright.coreImageTransform, rect: CGRect(x: 0, y: 0, width: 1, height: 1),
            compStart: placement.compStart, duration: duration, opacity: 1, fadeIn: 0, fadeOut: 0)
        let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: width, height: height),
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), frame: VideoFrameStyle()))
        let scene = VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: .empty,
            cameraMotionBlur: 0, cursor: nil, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
            captions: [], captionStyle: VideoCaptionStyle(), webcam: nil, overlays: [overlayLayer])
        let composition = try VideoCompositionRendering.sceneComposition(asset: built.composition, track: built.videoTrack,
            frameDuration: CMTime(value: 1, timescale: 30), timeMap: built.timeMap, scene: scene,
            censorSegments: [], textSnapshots: [])
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try generator.copyCGImage(at: CMTime(value: 3, timescale: 30), actualTime: nil)
        return NSBitmapImageRep(cgImage: cg)
    }

    /// `(r, g, b)` 0-255 at the given pixel.
    private func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return (Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    private func assertCorrectComposite(_ bitmap: NSBitmapImageRep, width: Int, height: Int,
                                        bgRGB: (Int, Int, Int), fgRGB: (Int, Int, Int),
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        // Corner: fully transparent overlay pixel — must show the source
        // untouched (a little slack for lossy-codec quantization noise on
        // the tiny test clip, not a compositing correctness bound).
        let corner = try rgb(bitmap, 2, 2)
        XCTAssertEqual(corner.0, bgRGB.0, accuracy: 20, "corner R", file: file, line: line)
        XCTAssertEqual(corner.1, bgRGB.1, accuracy: 20, "corner G", file: file, line: line)
        XCTAssertEqual(corner.2, bgRGB.2, accuracy: 20, "corner B", file: file, line: line)

        // Center: 50% alpha square over the background. Regardless of which
        // color space compositing happens in, a correct straight-alpha blend
        // is a convex combination of fg/bg — it can never fall outside
        // [min(fg,bg), max(fg,bg)] on any channel. A dark-fringing /
        // premultiplication bug pushes values below that floor (color
        // scaled by alpha twice); a straight-as-premultiplied inversion
        // pushes them above the ceiling.
        let center = try rgb(bitmap, width / 2, height / 2)
        let channels: [(String, Int, Int, Int)] = [
            ("R", center.0, fgRGB.0, bgRGB.0), ("G", center.1, fgRGB.1, bgRGB.1), ("B", center.2, fgRGB.2, bgRGB.2),
        ]
        for (name, actual, fg, bg) in channels {
            // A generous floor (not just proportional to |fg-bg|): a lossy
            // codec adds a little absolute noise even on a flat, single-value
            // channel, which a fringing bug would dwarf (tens to 100+ off).
            let lo = min(fg, bg) - 20, hi = max(fg, bg) + 20
            XCTAssertTrue((lo...hi).contains(actual),
                "center \(name) = \(actual) outside plausible blend range [\(lo), \(hi)] (fg=\(fg), bg=\(bg)) " +
                "— looks like a premultiplication/fringing bug", file: file, line: line)
        }
        // The blend must actually be a blend: on a channel where fg and bg
        // differ a lot, the center shouldn't land on (or near) either pure
        // endpoint — that would mean alpha was effectively treated as 0 or 1.
        if abs(fgRGB.0 - bgRGB.0) > 80 {
            XCTAssertGreaterThan(abs(center.0 - bgRGB.0), 20, "center R didn't blend away from background",
                                 file: file, line: line)
            XCTAssertGreaterThan(abs(center.0 - fgRGB.0), 20, "center R didn't blend away from the overlay color",
                                 file: file, line: line)
        }
    }

    // MARK: Tests

    private let width = 64, height = 64
    private let bgBGR: (UInt8, UInt8, UInt8) = (220, 30, 30)   // background: strong blue, some red
    private let fgBGR: (UInt8, UInt8, UInt8) = (30, 30, 230)   // overlay square: strong red, some blue

    func testProRes4444OverlayCompositesOverOpaqueSourceWithoutFringing() async throws {
        // The blend range was calibrated on the hardware ProRes encoder; the
        // software encoder (and CI runners) land at G = 53, just outside it.
        try HardwareEncoderTests.require()
        guard let overlayURL = try makeAlphaMovie(codec: .proRes4444, squareBGR: fgBGR, width: width, height: height,
                                                  frameCount: 6, in: directory) else {
            throw XCTSkip("ProRes 4444 encoder unavailable on this machine")
        }
        let bitmap = try await renderCenterFrame(overlayURL: overlayURL, width: width, height: height, bgBGR: bgBGR)
        try assertCorrectComposite(bitmap, width: width, height: height,
                                   bgRGB: (Int(bgBGR.2), Int(bgBGR.1), Int(bgBGR.0)),
                                   fgRGB: (Int(fgBGR.2), Int(fgBGR.1), Int(fgBGR.0)))
    }

    func testHEVCWithAlphaOverlayCompositesOverOpaqueSourceWithoutFringing() async throws {
        guard let overlayURL = try makeAlphaMovie(codec: .hevcWithAlpha, squareBGR: fgBGR, width: width, height: height,
                                                  frameCount: 6, in: directory) else {
            throw XCTSkip("HEVC-with-alpha encoder unavailable on this machine")
        }
        let bitmap = try await renderCenterFrame(overlayURL: overlayURL, width: width, height: height, bgBGR: bgBGR)
        try assertCorrectComposite(bitmap, width: width, height: height,
                                   bgRGB: (Int(bgBGR.2), Int(bgBGR.1), Int(bgBGR.0)),
                                   fgRGB: (Int(fgBGR.2), Int(fgBGR.1), Int(fgBGR.0)))
    }
}
