import AVFoundation
import CoreImage
import XCTest

/// Timing and placement behavior for media overlays (`VideoOverlaySegment`):
/// a video overlay gets its own composition track inserted at the
/// composition time its source `startTime` maps to (not through the cut/
/// speed/freeze piece loop), keeps animating through a freeze, is hidden
/// when its start falls in a cut, and never fails the whole build when its
/// media is missing. Rendering placement (content rect → canvas rect →
/// camera, drawn after text, before annotation layers) is exercised the same
/// way `VideoSceneRendererTests` exercises text boxes: synthetic CIImages,
/// no real video decoding needed.
final class VideoOverlayCompositionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Last, so tearDown always has a directory to remove.
        try MediaTests.require()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: compositionTime(forSource:) — pure mapping, no media needed

    func testCompositionTimeMapsSourceStartThroughAPrecedingCut() throws {
        // Trim 0…2 with [0, 0.5) cut away leaves one kept range (0.5, 2)
        // inserted at composition 0 — so source 1.0 lands at comp 0.5.
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2, cuts: [VideoCutSegment(startTime: 0, endTime: 0.5)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: [])
        let timeMap = pieces.reduce(into: (cursor: 0.0, map: [EffectsCompositionInstruction.TimeMapEntry]())) { acc, piece in
            let entry = EffectsCompositionInstruction.TimeMapEntry(compStart: acc.cursor,
                compEnd: acc.cursor + piece.compositionDuration, sourceStart: piece.srcStart, factor: piece.factor)
            acc.map.append(entry); acc.cursor += piece.compositionDuration
        }.map
        let compStart = try XCTUnwrap(VideoCompositionBuilder.compositionTime(forSource: 1.0, timeMap: timeMap))
        XCTAssertEqual(compStart, 0.5, accuracy: 0.001)
    }

    func testCompositionTimeIsNilWhenSourceStartFallsInsideACut() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2, cuts: [VideoCutSegment(startTime: 0.5, endTime: 1)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: [])
        let timeMap = pieces.reduce(into: (cursor: 0.0, map: [EffectsCompositionInstruction.TimeMapEntry]())) { acc, piece in
            let entry = EffectsCompositionInstruction.TimeMapEntry(compStart: acc.cursor,
                compEnd: acc.cursor + piece.compositionDuration, sourceStart: piece.srcStart, factor: piece.factor)
            acc.map.append(entry); acc.cursor += piece.compositionDuration
        }.map
        XCTAssertNil(VideoCompositionBuilder.compositionTime(forSource: 0.7, timeMap: timeMap))
    }

    func testCompositionTimeIsNilBeyondTheTrim() {
        let pieces = VideoSpeeds.pieces(keptRanges: [(0, 1)], speeds: [])
        let timeMap = [EffectsCompositionInstruction.TimeMapEntry(compStart: 0, compEnd: pieces[0].compositionDuration,
                                                                   sourceStart: 0, factor: 1)]
        XCTAssertNil(VideoCompositionBuilder.compositionTime(forSource: 1.5, timeMap: timeMap))
    }

    // MARK: Composition-track placement (real media, via VideoCompositionBuilder.build)

    func testOverlayAppearsAtTheCompositionTimeItsSourceStartMapsTo() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let overlayAsset = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 32, height: 32)))
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2, cuts: [VideoCutSegment(startTime: 0, endTime: 0.5)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: [])
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: overlayAsset, startTime: 1.0,
                                                                 duration: 0.5, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: source, pieces: pieces, includeAudio: false,
                                                      overlays: [overlayInput])
        let placement = try XCTUnwrap(built.overlayPlacements[overlayInput.id])
        XCTAssertEqual(placement.compStart, 0.5, accuracy: 0.01)
        let track = try XCTUnwrap(built.composition.track(withTrackID: placement.trackID))
        let segment = try XCTUnwrap(track.segment(forTrackTime: CMTime(seconds: 0.6, preferredTimescale: 600)))
        XCTAssertFalse(segment.isEmpty)
    }

    func testOverlayHiddenWhenItsStartFallsInsideACut() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let overlayAsset = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 32, height: 32)))
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2, cuts: [VideoCutSegment(startTime: 0.5, endTime: 1)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: [])
        // 0.7 falls inside the removed [0.5, 1) range.
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: overlayAsset, startTime: 0.7,
                                                                 duration: 0.3, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: source, pieces: pieces, includeAudio: false,
                                                      overlays: [overlayInput])
        XCTAssertNil(built.overlayPlacements[overlayInput.id])
    }

    func testOverlayHiddenPastTheTrim() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let overlayAsset = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 32, height: 32)))
        let pieces = VideoSpeeds.pieces(keptRanges: [(0, 1)], speeds: [])
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: overlayAsset, startTime: 1.5,
                                                                 duration: 0.3, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: source, pieces: pieces, includeAudio: false,
                                                      overlays: [overlayInput])
        XCTAssertNil(built.overlayPlacements[overlayInput.id])
    }

    /// The overlay's own composition track is inserted once, un-scaled, so it
    /// keeps advancing through source time at its own pace even while the
    /// main/camera track holds a single frozen frame for a whole second.
    func testOverlayKeepsAnimatingThroughAFreeze() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let overlayAsset = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 32, height: 32)))
        let pieces = VideoSpeeds.pieces(keptRanges: [(0, 2)], speeds: [],
                                        freezes: [VideoFreezeSegment(atTime: 1, holdDuration: 1)])
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: overlayAsset, startTime: 0,
                                                                 duration: 2, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: source, pieces: pieces, includeAudio: false,
                                                      overlays: [overlayInput])
        let placement = try XCTUnwrap(built.overlayPlacements[overlayInput.id])
        XCTAssertEqual(placement.compStart, 0, accuracy: 0.01)
        let track = try XCTUnwrap(built.composition.track(withTrackID: placement.trackID))
        // The freeze hold occupies composition 1s...2s. The overlay's own
        // media time must keep moving forward across that window, unlike the
        // frozen main video (see `VideoStudioMediaTests.testFreezeHoldsASingleCameraFrame`).
        let early = try XCTUnwrap(track.segment(forTrackTime: CMTime(seconds: 1.1, preferredTimescale: 600)))
        let late = try XCTUnwrap(track.segment(forTrackTime: CMTime(seconds: 1.9, preferredTimescale: 600)))
        XCTAssertFalse(early.isEmpty); XCTAssertFalse(late.isEmpty)
        // `timeMapping` describes the whole (unscaled, 1:1) segment, not a
        // point sample — project each query time through it to get the
        // overlay's own source instant at that composition time.
        func overlaySourceTime(_ segment: AVCompositionTrackSegment, at query: CMTime) -> Double {
            segment.timeMapping.source.start.seconds + (query.seconds - segment.timeMapping.target.start.seconds)
        }
        let earlyTime = overlaySourceTime(early, at: CMTime(seconds: 1.1, preferredTimescale: 600))
        let lateTime = overlaySourceTime(late, at: CMTime(seconds: 1.9, preferredTimescale: 600))
        XCTAssertGreaterThan(lateTime, earlyTime + 0.3, "overlay media should keep advancing through the freeze")
    }

    /// A video overlay whose media can't be read (here: no video track at
    /// all) is simply skipped — the rest of the build still succeeds.
    func testUnreadableOverlayMediaIsSkippedNotFailed() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let brokenAsset = AVURLAsset(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mov"))
        let overlayInput = VideoCompositionBuilder.OverlayInput(id: UUID(), asset: brokenAsset, startTime: 0,
                                                                 duration: 1, mediaStart: 0)
        let built = try VideoCompositionBuilder.build(asset: source,
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: 2, compositionDuration: 2)],
            includeAudio: false, overlays: [overlayInput])
        XCTAssertNil(built.overlayPlacements[overlayInput.id])
        XCTAssertEqual(built.duration, 2, accuracy: 0.01, "an unreadable overlay must not fail the whole composition")
    }

    // MARK: - Persistence (rotation)

    func testRotationRoundTrips() throws {
        let segment = VideoOverlaySegment(kind: .image, fileName: "a.png", displayName: "a.png", startTime: 0,
                                          duration: 2, mediaDuration: 0, mediaSize: CGSize(width: 10, height: 10),
                                          rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), rotation: .pi / 4)
        let project = VideoProject(sourceDuration: 10, look: VideoLook())
        project.overlays = [segment]
        let copy = try XCTUnwrap(project.copy())
        XCTAssertEqual(copy.encoded(), project.encoded())
        XCTAssertEqual(copy.overlays[0].rotation, .pi / 4, accuracy: 1e-9)
    }

    /// A project saved before overlay rotation existed has no `rotation` key
    /// at all — must decode to 0 (no rotation), not fail the whole overlay.
    func testRotationDecodesToZeroWhenAbsent() throws {
        let json = """
        {"sourceDuration": 5, "overlays": [
          {"kind": "image", "fileName": "a.png", "displayName": "a.png", "startTime": 0,
           "duration": 2, "mediaDuration": 0, "mediaSize": {"width": 10, "height": 10},
           "rect": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}}
        ]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        XCTAssertEqual(project.overlays.first?.rotation, 0)
    }

    // MARK: Rendering placement — synthetic CIImages, no video decode needed

    private let contentSize = CGSize(width: 400, height: 200)

    private var content: CIImage {
        CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: contentSize))
    }

    private func layout() -> VideoSceneLayout {
        VideoSceneGeometry.layout(contentSize: contentSize, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  frame: VideoFrameStyle())!
    }

    private func snapshot(_ layout: VideoSceneLayout, overlays: [VideoOverlayLayer]) -> VideoSceneSnapshot {
        VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: .empty, cameraMotionBlur: 0,
                           cursor: nil, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(), captions: [],
                           captionStyle: VideoCaptionStyle(), webcam: nil, overlays: overlays)
    }

    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func pixel(_ image: CIImage, _ x: Int, _ yTop: Int) -> [UInt8] {
        let extent = image.extent
        var bytes = [UInt8](repeating: 0, count: 4)
        let y = Int(extent.height) - 1 - yTop
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func assertColor(_ rgba: [UInt8], _ r: UInt8, _ g: UInt8, _ b: UInt8,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Int(rgba[0]), Int(r), accuracy: 12, "red", file: file, line: line)
        XCTAssertEqual(Int(rgba[1]), Int(g), accuracy: 12, "green", file: file, line: line)
        XCTAssertEqual(Int(rgba[2]), Int(b), accuracy: 12, "blue", file: file, line: line)
    }

    /// A still-image overlay is placed exactly like a text box: its
    /// content-normalized `rect` lands at the matching canvas pixels.
    func testStillImageOverlayRendersAtItsRect() {
        let layout = layout()
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let overlay = VideoOverlayLayer(id: UUID(), trackID: nil, stillImage: green, uprightTransform: .identity,
            rect: CGRect(x: 0.6, y: 0, width: 0.2, height: 0.5), compStart: 0, duration: 5,
            opacity: 1, fadeIn: 0, fadeOut: 0)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot(layout, overlays: [overlay]),
                                              censors: [], texts: [], compositionTime: 1)
        // rect (0.6, 0, 0.2, 0.5) in a 400x200 canvas → x 240...320, top half.
        assertColor(pixel(image, 280, 50), 0, 255, 0)
        assertColor(pixel(image, 100, 50), 255, 0, 0)
        assertColor(pixel(image, 280, 150), 255, 0, 0)
    }

    /// Before its window and after it, the overlay is invisible.
    func testOverlayIsHiddenOutsideItsCompositionWindow() {
        let layout = layout()
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let overlay = VideoOverlayLayer(id: UUID(), trackID: nil, stillImage: green, uprightTransform: .identity,
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), compStart: 2, duration: 1,
            opacity: 1, fadeIn: 0, fadeOut: 0)
        let before = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot(layout, overlays: [overlay]),
                                               censors: [], texts: [], compositionTime: 1)
        let after = VideoSceneRenderer.render(content: content, time: 4, scene: snapshot(layout, overlays: [overlay]),
                                              censors: [], texts: [], compositionTime: 4)
        assertColor(pixel(before, 50, 50), 255, 0, 0)
        assertColor(pixel(after, 50, 50), 255, 0, 0)
        let during = VideoSceneRenderer.render(content: content, time: 2.5, scene: snapshot(layout, overlays: [overlay]),
                                               censors: [], texts: [], compositionTime: 2.5)
        assertColor(pixel(during, 50, 50), 0, 255, 0)
    }

    /// A video overlay whose source frame isn't available this instant
    /// (unreadable/exhausted media) is skipped, not drawn as garbage.
    func testVideoOverlayWithNoAvailableFrameIsSkipped() {
        let layout = layout()
        let overlay = VideoOverlayLayer(id: UUID(), trackID: 99, stillImage: nil, uprightTransform: .identity,
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), compStart: 0, duration: 5,
            opacity: 1, fadeIn: 0, fadeOut: 0)
        // overlayFrames intentionally omitted — simulates `sourceFrame(byTrackID:)` returning nil.
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot(layout, overlays: [overlay]),
                                              censors: [], texts: [], compositionTime: 1)
        assertColor(pixel(image, 50, 50), 255, 0, 0)
    }

    /// `rotation` turns the overlay about its own rect's center, pre-camera,
    /// in canvas-pixel space — same rule the annotation stage transform uses
    /// (see `VideoSceneRendererTests.testNinetyDegreeRotationSwingsLayersAroundThePivot`).
    /// A 90° (clockwise, as seen on screen) turn swings an off-center marker
    /// from due east of the rect's center to due south of it.
    func testOverlayRotationTurnsAboutItsOwnRectCenter() {
        let layout = layout()
        // A square 100x100-canvas-pixel rect centered on the 400x200
        // canvas's own center (200, 100), holding a square 100x100 media
        // (scale factor 1, so the marker's offset survives unscaled) with a
        // small green marker 30px east of its center, red elsewhere.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let marker = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 75, y: 45, width: 10, height: 10))
        let media = marker.composited(over: red)
        let overlay = VideoOverlayLayer(id: UUID(), trackID: nil, stillImage: media, uprightTransform: .identity,
            rect: CGRect(x: 0.375, y: 0.25, width: 0.25, height: 0.5), compStart: 0, duration: 5,
            opacity: 1, fadeIn: 0, fadeOut: 0, rotation: .pi / 2)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot(layout, overlays: [overlay]),
                                              censors: [], texts: [], compositionTime: 1)
        // rect (0.375, 0.25, 0.25, 0.5) on a 400x200 canvas -> canvas pixels
        // (150, 50, 100, 100), center (200, 100) — matching the media's own
        // 1:1 scale, the marker (media-local center (80, 50), 30px east of
        // the media's own center (50, 50)) sits 30px east of the rect's
        // center before rotation. Rotated 90° clockwise, east -> south.
        assertColor(pixel(image, 200, 130), 0, 255, 0)
        // Its old (unrotated) east-of-center spot is red now.
        assertColor(pixel(image, 230, 100), 255, 0, 0)
    }

    /// Timing lives on the composition clock, not source/asset time.
    func testOverlayOpacityWindowIsOnTheCompositionClock() {
        let overlay = VideoOverlayLayer(id: UUID(), trackID: nil, stillImage: nil, uprightTransform: .identity,
            rect: .zero, compStart: 2, duration: 3, opacity: 1, fadeIn: 0, fadeOut: 0)
        XCTAssertEqual(overlay.opacity(atComposition: 1), 0)
        XCTAssertEqual(overlay.opacity(atComposition: 3.5), 1)
        XCTAssertEqual(overlay.opacity(atComposition: 6), 0)
    }
}
