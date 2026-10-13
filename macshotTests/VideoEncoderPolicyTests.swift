import AVFoundation
import VideoToolbox
import XCTest

/// The suite must encode in software (docs/feedback/2026-10-13-ave-dart-panic.md).
final class VideoEncoderPolicyTests: XCTestCase {
    func testTheTestRunnerRequestsSoftwareEncoding() throws {
        try XCTSkipIf(HardwareEncoderTests.isEnabled, "Hardware encoder test mode uses the hardware encoder")
        XCTAssertTrue(VideoEncoderPolicy.forcesSoftware,
            "Run through scripts/run-tests.sh or the macshotTests scheme, which set \(VideoEncoderPolicy.softwareEnvironmentKey)=1")
    }

    func testCompressedOutputSettingsCarryTheEncoderSpecification() throws {
        try XCTSkipUnless(VideoEncoderPolicy.forcesSoftware)
        for codec in [VideoCodec.h264, .hevc] {
            let settings = VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30, codec: codec, quality: .high)
            let specification = try XCTUnwrap(settings[AVVideoEncoderSpecificationKey] as? [String: Any])
            XCTAssertEqual(specification[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool, false)
            XCTAssertTrue(AVAssetWriterInput(mediaType: .video, outputSettings: settings).outputSettings != nil)
        }
        XCTAssertNil(VideoEncoderPolicy.applying(toOptional: nil), "Passthrough settings stay passthrough")
        let audio: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC]
        XCTAssertNil(VideoEncoderPolicy.applying(to: audio)[AVVideoEncoderSpecificationKey])
    }

    /// The same specification, given to VideoToolbox directly, yields sessions
    /// that report software encoding for both codecs the app writes.
    func testTheSpecificationSelectsSoftwareEncoders() throws {
        try XCTSkipIf(HardwareEncoderTests.isEnabled, "Hardware encoder test mode uses the hardware encoder")
        let specification = try XCTUnwrap(VideoEncoderPolicy.encoderSpecification,
                                          "Requires \(VideoEncoderPolicy.softwareEnvironmentKey)=1")
        for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
            var session: VTCompressionSession?
            let created = VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: codec,
                encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
            XCTAssertEqual(created, noErr)
            let compression = try XCTUnwrap(session)
            defer { VTCompressionSessionInvalidate(compression) }
            // Software encoders don't implement UsingHardwareAcceleratedVideoEncoder
            // (kVTPropertyNotSupportedErr); a hardware one would report true.
            var hardware: CFTypeRef?
            let hardwareStatus = withUnsafeMutablePointer(to: &hardware) {
                VTSessionCopyProperty(compression, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                      allocator: nil, valueOut: $0)
            }
            if hardwareStatus == noErr { XCTAssertEqual(hardware as? Bool, false) }
            else { XCTAssertEqual(hardwareStatus, kVTPropertyNotSupportedErr) }
            var encoderID: CFTypeRef?
            let idStatus = withUnsafeMutablePointer(to: &encoderID) {
                VTSessionCopyProperty(compression, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: $0)
            }
            XCTAssertEqual(idStatus, noErr)
            let identifier = try XCTUnwrap(encoderID as? String)
            XCTAssertFalse(identifier.contains(".ave."), "codec \(codec) uses the Apple Video Encoder: \(identifier)")
            print("VideoEncoderPolicyTests: codec \(codec) -> \(identifier)")
        }
    }
}
