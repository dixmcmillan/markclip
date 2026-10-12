import Foundation

/// Pure J/K/L shuttle state machine (Premiere/Resolve transport conventions).
/// No AVFoundation dependency, so it's testable without a player: callers
/// (`VideoEditorPlayback`) read `rate` after each press and apply it to the
/// player (or a frame-stepping fallback when reverse playback isn't
/// supported — see `VideoEditorPlayback.applyShuttleRate()`).
///
/// **K+L / K+J (slow motion):** a following L/J counts as "K held" when it
/// arrives within `chordWindow` of the most recent K press. AppKit delivers
/// repeated `keyDown` events (with `isARepeat == true`) for a physically
/// held key at well under this window, so a caller that forwards every K
/// keyDown (repeats included) to `pressK(at:)` gets correct held-chord
/// detection for free, with no separate keyUp/held-state tracking needed.
struct VideoPlaybackShuttle: Equatable {
    /// L/J repeated-press ladder (Premiere convention: 1x, 2x, 4x, 8x).
    static let ladder: [Double] = [1, 2, 4, 8]
    /// K+L / K+J slow-motion rate. AVPlayer plays 0.5x smoothly in both
    /// directions (when reverse is supported); slower rates cost more CPU
    /// for the same benefit, so this app picked a single fixed slow rate
    /// rather than its own ladder.
    static let slowRate: Double = 0.5
    /// Discrete speeds offered by the Playback ▸ Play Speed menu and by
    /// Faster/Slower.
    static let speedSteps: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    /// How recently K must have been pressed (including auto-repeats from
    /// being held) for a following L/J to be treated as the slow-motion
    /// chord instead of the normal shuttle ladder.
    static let chordWindow: TimeInterval = 0.35

    /// Signed playback rate. 0 = paused, negative = reverse.
    private(set) var rate: Double = 0
    private var lastKTimestamp: TimeInterval?

    init() {}

    /// K: pause. Also arms the K+L/K+J slow-motion chord window.
    mutating func pressK(at timestamp: TimeInterval) {
        rate = 0
        lastKTimestamp = timestamp
    }

    /// L: play forward, or step up the ladder if already playing forward.
    /// K+L (K held) instead sets the fixed slow-forward rate.
    mutating func pressL(at timestamp: TimeInterval) {
        if kIsHeld(at: timestamp) {
            rate = Self.slowRate
            return
        }
        if rate > 0, let index = Self.ladder.firstIndex(of: rate) {
            rate = Self.ladder[min(index + 1, Self.ladder.count - 1)]
        } else {
            rate = 1
        }
    }

    /// J: play in reverse, or step up the ladder if already playing reverse.
    /// K+J (K held) instead sets the fixed slow-reverse rate.
    mutating func pressJ(at timestamp: TimeInterval) {
        if kIsHeld(at: timestamp) {
            rate = -Self.slowRate
            return
        }
        if rate < 0, let index = Self.ladder.firstIndex(of: -rate) {
            rate = -Self.ladder[min(index + 1, Self.ladder.count - 1)]
        } else {
            rate = -1
        }
    }

    /// Space: toggle play/pause. This app's decision (see ROADMAP Phase 2):
    /// Space always normalizes to 1x forward rather than resuming whatever
    /// shuttle rate was last active, so it stays a predictable "just play"
    /// key independent of J/K/L state. Pausing with Space (like K) forgets
    /// the shuttle rate; pressing L afterward starts over at 1x.
    mutating func toggleSpace() {
        rate = rate == 0 ? 1 : 0
    }

    /// Directly sets a rate (Playback menu speed items, scrubbing helpers).
    /// Sign is preserved from the caller; 0 pauses.
    mutating func setDirectRate(_ value: Double) {
        rate = value
    }

    /// Faster: step to the next speed in `speedSteps` above the current
    /// magnitude, preserving direction. Starts forward playback at the
    /// slowest step above 1x if currently paused. Clamped at the fastest step.
    mutating func faster() {
        let sign: Double = rate < 0 ? -1 : 1
        let magnitude = rate == 0 ? 1 : abs(rate)
        let index = Self.closestSpeedIndex(to: magnitude)
        rate = sign * Self.speedSteps[min(index + 1, Self.speedSteps.count - 1)]
    }

    /// Slower: step to the next speed in `speedSteps` below the current
    /// magnitude, preserving direction. Clamped at the slowest step.
    mutating func slower() {
        let sign: Double = rate < 0 ? -1 : 1
        let magnitude = rate == 0 ? 1 : abs(rate)
        let index = Self.closestSpeedIndex(to: magnitude)
        rate = sign * Self.speedSteps[max(index - 1, 0)]
    }

    private static func closestSpeedIndex(to value: Double) -> Int {
        speedSteps.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 2
    }

    private func kIsHeld(at timestamp: TimeInterval) -> Bool {
        guard let lastKTimestamp else { return false }
        return timestamp - lastKTimestamp <= Self.chordWindow
    }

    var isPlaying: Bool { rate != 0 }

    /// Whether the transient rate HUD should be shown: anything other than
    /// paused or normal 1x forward playback. Reverse at "1x" (`rate == -1`)
    /// still shows it — direction alone is worth flagging, not just speed.
    var showsRateHUD: Bool { rate != 0 && rate != 1 }
}
