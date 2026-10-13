import AVFoundation
import VideoToolbox

/// Which video encoder AVFoundation may pick. Hardware stays the default for
/// users. `MACSHOT_SOFTWARE_ENCODER=1` (set by the test scheme and
/// `scripts/run-tests.sh`) asks VideoToolbox for its software encoders: the
/// test suite's rapid start/stop of hardware sessions triggered a kernel panic
/// in the Apple Video Encoder's IOMMU (docs/feedback/2026-10-13-ave-dart-panic.md).
///
/// Every `AVAssetWriterInput` that compresses video goes through `applying(to:)`.
/// `AVAssetExportSession` has no encoder-specification hook, so tests that need
/// it are gated separately (`MACSHOT_HARDWARE_ENCODER_TESTS=1`).
nonisolated enum VideoEncoderPolicy {
    static let softwareEnvironmentKey = "MACSHOT_SOFTWARE_ENCODER"
    /// Opt-in hardware test mode: the run deliberately exercises the hardware
    /// encoder, so it overrides the software request.
    static let hardwareTestsEnvironmentKey = "MACSHOT_HARDWARE_ENCODER_TESTS"

    static let forcesSoftware: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment[softwareEnvironmentKey] == "1" && environment[hardwareTestsEnvironmentKey] != "1"
    }()

    /// `encoderSpecification` for `VTCompressionSessionCreate`, or nil for the
    /// system default (hardware when available).
    static var encoderSpecification: [String: Any]? {
        forcesSoftware ? [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false] : nil
    }

    /// Adds the encoder specification to compressed video output settings.
    /// Passthrough (`nil`) settings and settings that already choose an
    /// encoder are returned unchanged.
    static func applying(toOptional settings: [String: Any]?) -> [String: Any]? {
        guard let settings, settings[AVVideoCodecKey] != nil,
              settings[AVVideoEncoderSpecificationKey] == nil,
              let specification = encoderSpecification else { return settings }
        var result = settings
        result[AVVideoEncoderSpecificationKey] = specification
        return result
    }

    static func applying(to settings: [String: Any]) -> [String: Any] {
        applying(toOptional: settings) ?? settings
    }
}
