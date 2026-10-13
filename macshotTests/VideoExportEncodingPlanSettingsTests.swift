import AVFoundation
import XCTest

/// Pure plan arithmetic for codec, frame-rate cap and explicit bitrate. No
/// encoder session is created, so unlike `VideoExportEncodingPlanTests` this
/// class is not media-gated and runs locally.
final class VideoExportEncodingPlanSettingsTests: XCTestCase {
    private func source(rate: Double = 2_000_000, codec: CMVideoCodecType? = kCMVideoCodecType_H264,
                        fps: Double = 30, period: Double = 1.0 / 30,
                        size: CGSize = CGSize(width: 1920, height: 1080)) -> VideoExportEncodingPlan.Source {
        .init(size: size, averageBitrate: rate, codec: codec, nominalFPS: fps, minimumFrameDuration: period)
    }

    private func custom(_ source: VideoExportEncodingPlan.Source, quality: VideoQuality = .high,
                        codec: VideoCodec = .h264, fpsCap: Int? = nil,
                        explicitBitrate: Int? = nil) throws -> VideoExportEncodingPlan {
        try XCTUnwrap(VideoExportEncodingPlan.make(source: source, scale: 1, quality: quality, codec: codec,
            fpsCap: fpsCap, explicitBitrate: explicitBitrate, sourceDuration: 120, outputDuration: 120))
    }

    func testHEVCPlanWritesAnHEVCSettingsDictionaryWithoutH264Keys() throws {
        let hevc = try custom(source(), codec: .hevc)
        XCTAssertEqual(hevc.codec, .hevc)
        let settings = hevc.outputSettings
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1920)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 1080)
        let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, hevc.videoBitrate)
        XCTAssertNil(compression[AVVideoProfileLevelKey], "H.264 profile levels are invalid for HEVC")
        XCTAssertNil(compression[AVVideoH264EntropyModeKey])
        XCTAssertEqual(try custom(source()).outputSettings[AVVideoCodecKey] as? AVVideoCodecType, .h264)
    }

    func testHEVCHighUsesTheHighBitsPerPixelBudget() throws {
        // Not sparse-source-capped: HEVC output from a non-comparable source
        // uses the pixel budget, clamped to the tier maximum.
        let high = try custom(source(codec: kCMVideoCodecType_HEVC), codec: .hevc)
        XCTAssertEqual(high.videoBitrate, 24_883_200) // 1920 x 1080 x 30 x 0.40
        XCTAssertGreaterThan(high.videoBitrate, try custom(source(codec: kCMVideoCodecType_HEVC), quality: .medium,
                                                           codec: .hevc).videoBitrate)
    }

    func testFPSCapLowersCadenceButNeverRaisesIt() throws {
        let sixty = source(rate: .nan, fps: 60, period: 1.0 / 60)
        let capped = try custom(sixty, fpsCap: 30)
        XCTAssertEqual(capped.fps, 30)
        XCTAssertEqual(capped.frameDuration, CMTime(value: 1, timescale: 30))
        XCTAssertLessThan(capped.videoBitrate, try custom(sixty).videoBitrate, "half the frames, smaller budget")
        let uncapped = try custom(sixty)
        XCTAssertEqual(uncapped.fps, 60)
        XCTAssertEqual(uncapped.frameDuration.seconds, 1.0 / 60, accuracy: 1e-6)
        // A cap above (or at) the source rate is a no-op, never an upsample.
        for cap in [60, 120, 240] {
            let plan = try custom(sixty, fpsCap: cap)
            XCTAssertEqual(plan.fps, 60, "cap \(cap)")
            XCTAssertEqual(plan.frameDuration.seconds, 1.0 / 60, accuracy: 1e-6)
        }
        XCTAssertEqual(try custom(source(), fpsCap: 60).fps, 30)
        XCTAssertEqual(try custom(source(), fpsCap: 24).frameDuration, CMTime(value: 1, timescale: 24))
        XCTAssertEqual(try custom(source(), fpsCap: 0).fps, 30, "a non-positive cap is ignored")
    }

    func testFPSCapKeepsRationalCadenceWhenItDoesNotApply() throws {
        var ntsc = source(fps: 60_000.0 / 1001, period: 1001.0 / 60_000)
        ntsc.frameDuration = CMTime(value: 1001, timescale: 60_000)
        let kept = try custom(ntsc, fpsCap: 60)
        XCTAssertEqual(kept.frameDuration, CMTime(value: 1001, timescale: 60_000))
        XCTAssertEqual(try custom(ntsc, fpsCap: 30).frameDuration, CMTime(value: 1, timescale: 30))
    }

    func testFPSCapUsesTheResolvedCadenceNotTheShortestSample() throws {
        // An idle-heartbeat recording: shortest sample suggests 74 fps, but the
        // intended cadence is 30. A 60 cap must not "cap" anything.
        var recording = source(rate: 430_000, fps: 15.48, period: 0.01345)
        recording.frameDuration = CMTime(value: 1, timescale: 30)
        XCTAssertEqual(try custom(recording, fpsCap: 60).frameDuration, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(try custom(recording, fpsCap: 15).fps, 15)
    }

    func testExplicitBitrateOverridesQualityAndIsClampedToASaneRange() throws {
        for quality in [VideoQuality.low, .medium, .high] {
            XCTAssertEqual(try custom(source(), quality: quality, explicitBitrate: 8_000_000).videoBitrate, 8_000_000)
        }
        // Above the tier maximum is still honored: the user asked for it.
        XCTAssertEqual(try custom(source(), quality: .low, explicitBitrate: 100_000_000).videoBitrate, 100_000_000)
        XCTAssertEqual(try custom(source(), explicitBitrate: 1).videoBitrate,
                       VideoExportEncodingPlan.explicitBitrateRange.lowerBound)
        XCTAssertEqual(try custom(source(), explicitBitrate: Int.max).videoBitrate,
                       VideoExportEncodingPlan.explicitBitrateRange.upperBound)
        XCTAssertNil(VideoExportEncodingPlan.make(source: source(), scale: 1, quality: .high, explicitBitrate: 0,
            sourceDuration: 120, outputDuration: 120))
        XCTAssertNil(VideoExportEncodingPlan.make(source: source(), scale: 1, quality: .high, explicitBitrate: -5,
            sourceDuration: 120, outputDuration: 120))
        let compression = try XCTUnwrap(custom(source(), explicitBitrate: 8_000_000)
            .outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, 8_000_000)
    }

    func testSizeEstimatesAreH264OnlyAndExplicitBitrateMakesHighEstimable() throws {
        XCTAssertNotNil(try custom(source(), quality: .medium)
            .estimatedBytes(duration: 60, audioTrackCount: 1, audioBitrate: 128_000))
        for quality in [VideoQuality.low, .medium, .high] {
            XCTAssertNil(try custom(source(), quality: quality, codec: .hevc)
                .estimatedBytes(duration: 60, audioTrackCount: 1, audioBitrate: 128_000), "HEVC \(quality)")
            XCTAssertNil(try custom(source(), quality: quality, codec: .hevc, explicitBitrate: 4_000_000)
                .estimatedBytes(duration: 60, audioTrackCount: 1, audioBitrate: 128_000))
        }
        let explicit = try custom(source(), explicitBitrate: 8_000_000)
        let bytes = try XCTUnwrap(explicit.estimatedBytes(duration: 60, audioTrackCount: 0, audioBitrate: 128_000))
        XCTAssertEqual(Double(bytes), 8_000_000.0 * 60 / 8 * 1.03, accuracy: 100_000)
        XCTAssertNil(try custom(source(rate: .nan), explicitBitrate: 8_000_000)
            .estimatedBytes(duration: 60, audioTrackCount: 0, audioBitrate: 128_000),
            "an unknown or sparse source still omits estimates")
    }
}
