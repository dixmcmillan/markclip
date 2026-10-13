import AVFoundation
import XCTest

/// CI only (`MediaTests.require()`): the real renderer through `ExportRun`,
/// with a fake Cloudflare. Locally this class skips, so no encoder starts.
@MainActor
final class ExportRunMediaTests: XCTestCase {
    private var root: URL!
    private let cleanup = DispatchQueue(label: "macshot.tests.export-run-cleanup")
    private var documents: [VideoEditorDocument] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("export-run-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Last, so tearDown always has a directory to remove.
        try MediaTests.require()
    }
    override func tearDownWithError() throws {
        documents.removeAll()
        cleanup.sync {}
        try? FileManager.default.removeItem(at: root)
    }

    private func writeVideo(width: Int = 96, height: Int = 64, fps: Int32 = 10, frames: Int = 10) async throws -> URL {
        let url = root.appendingPathComponent("source-" + UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncoderPolicy.applying(to: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ]))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 0x40 + Int32(frame * 8), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private func makeEnvironment(remote: FakeRemote, configure: (VideoProject) -> Void = { _ in }) async throws -> ExportEnvironment {
        let source = try await writeVideo()
        let snapshot = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
            workspaceRoot: root.appendingPathComponent("working"), cleanupQueue: cleanup)
        let prepared = try await PreparedVideoSource.load(snapshot)
        let document = VideoEditorDocument(prepared: prepared, asset: try XCTUnwrap(prepared.asset))
        configure(document.project)
        documents.append(document)
        let exporter = VideoEditorExporter(document: document)
        return ExportEnvironment(
            projectName: "Media Clip", renderer: EditorExportRenderer(exporter: exporter, document: document),
            records: ExportRecordStore(url: nil), remote: { remote },
            localFolderForUploads: { [root] in root!.appendingPathComponent("Archive") },
            coordinator: MediaExportCoordinator(), clock: InstantExportClock(), offline: false,
            stagingRoot: root.appendingPathComponent("staging"))
    }

    private func decodedFrames(_ url: URL) throws -> Int {
        let asset = AVAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return count
    }

    func testStreamPresetRendersPublishesAndUploadsTheSameDecodableFile() async throws {
        let remote = FakeRemote()
        let env = try await makeEnvironment(remote: remote) {
            $0.captions = [VideoCaptionSegment(startTime: 0, endTime: 0.5, text: "Hello captions")]
        }
        let preset = ExportPreset(name: "Stream", format: .h264, longEdgeCap: 64, fpsCap: 5, quality: .medium,
                                  explicitBitrate: 500_000, audio: .keep, captions: .soft,
                                  destination: .stream, alsoSaveLocally: true)
        let result = await ExportRun(preset: preset, environment: env).run()
        XCTAssertTrue(result.succeeded, "\(String(describing: result.failure))")

        let local = try XCTUnwrap(result.localFile)
        XCTAssertEqual(local.lastPathComponent, "Media Clip.mp4")
        XCTAssertGreaterThan(try decodedFrames(local), 0)
        let sidecar = try XCTUnwrap(result.captionsSidecar)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("Hello captions"))
        XCTAssertTrue(remote.calls.contains { $0.hasPrefix("putCaptions:uid-1:en:") && $0.contains("Hello captions") })
        XCTAssertEqual(remote.uploadedBytes.first, try Data(contentsOf: local))
        XCTAssertEqual(env.records.record(for: preset.id)?.state, .processing)
    }

    func testArchiveCopiesAnUneditedSourceWithoutReencoding() async throws {
        let remote = FakeRemote()
        let env = try await makeEnvironment(remote: remote)
        let folder = root.appendingPathComponent("Archive")
        let preset = ExportPreset(name: "Archive", format: .h264, quality: .high,
                                  destination: .folder(bookmark: nil, path: folder.path))
        let result = await ExportRun(preset: preset, environment: env).run()
        XCTAssertTrue(result.succeeded, "\(String(describing: result.failure))")
        XCTAssertEqual(try decodedFrames(try XCTUnwrap(result.localFile)), 10)
    }

    func testLoopPresetUploadsAFittedGIF() async throws {
        let remote = FakeRemote()
        let env = try await makeEnvironment(remote: remote)
        let preset = ExportPreset(name: "Loop", format: .gif, audio: .mute, destination: .images)
        let result = await ExportRun(preset: preset, environment: env).run()
        XCTAssertTrue(result.succeeded, "\(String(describing: result.failure))")
        XCTAssertEqual(remote.calls, ["uploadImage"])
        XCTAssertEqual(remote.uploadedBytes.first.map { String(decoding: $0.prefix(4), as: UTF8.self) }, "GIF8")
        XCTAssertNil(result.localFile)
        XCTAssertEqual(env.records.record(for: preset.id)?.state, .ready)
    }
}
