import AVFoundation

/// Drives preview playback. Timing edits (cuts, speed, freezes) swap in a
/// new player item; visual edits only replace the item's composition, which
/// is flicker-free. All times exposed to the UI are source-asset seconds.
@MainActor
final class VideoEditorPlayback {
    let player = AVPlayer()
    private let document: VideoEditorDocument
    let planner: VideoRenderPlanner

    /// Preview render scale relative to the native canvas.
    var previewScale: CGFloat = 0.5 {
        didSet { if abs(previewScale - oldValue) > 0.001 { scheduleRebuild(item: false) } }
    }
    var options = VideoRenderPlanner.Options() {
        didSet { scheduleRebuild(item: false) }
    }

    /// Called about 60 times a second while playing, and after every seek.
    var onTime: ((Double) -> Void)?
    /// Play/pause state changed.
    var onPlayStateChange: ((Bool) -> Void)?
    /// A preview composition could not be built.
    var onError: ((String) -> Void)?
    /// The shuttle rate changed (J/K/L, Space, Playback menu). Callers use
    /// this to drive the transient rate HUD.
    var onRateChange: ((Double) -> Void)?

    /// J/K/L shuttle state — pure logic lives in `VideoPlaybackShuttle`, this
    /// class only maps its `rate` onto the player.
    private(set) var shuttle = VideoPlaybackShuttle()
    /// Set once we discover (per player item) whether reverse rates are
    /// supported. When they aren't, negative rates are simulated by
    /// frame-stepping on a timer instead of setting `player.rate` negative.
    private var reverseTimer: Timer?

    private var mapping = VideoTimelineMapping(entries: [])
    private var usesComposition = false
    private var topology = ""
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var rebuildScheduled = false
    private var rebuildItem = false
    private var seekInFlight = false
    private var pendingSeek: CMTime?
    private var requestedSourceTime: Double?
    private(set) var currentSourceTime: Double = 0
    private var observerID: UUID?

    /// Authoritative "are we trying to play" state. Deliberately the shuttle's
    /// state, not `player.rate != 0`: when reverse isn't supported by the
    /// current item, playback is simulated by frame-stepping with the player
    /// paused (`player.rate` stays 0 the whole time) — see `applyShuttleRate()`.
    var isPlaying: Bool { shuttle.isPlaying }

    init(document: VideoEditorDocument) {
        self.document = document
        planner = VideoRenderPlanner(document: document)
        player.actionAtItemEnd = .pause
        player.isMuted = document.project.muted
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onPlayStateChange?(self.isPlaying)
            }
        }
        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.timing) { self.scheduleRebuild(item: true) }
            else if change.contains(.render) || change.contains(.segments) { self.scheduleRebuild(item: false) }
            if change.contains(.render) { self.player.isMuted = self.document.project.muted }
        }
        rebuild(forceItem: true)
    }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        stopReverseTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Composition

    private func scheduleRebuild(item: Bool) {
        rebuildItem = rebuildItem || item
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            let forceItem = self.rebuildItem
            self.rebuildItem = false
            self.rebuild(forceItem: forceItem)
        }
    }

    private func topologyKey() -> String {
        let p = document.project
        let cuts = p.cuts.map { "c\($0.startTime.bitPattern)-\($0.endTime.bitPattern)" }
        let speeds = p.speeds.map { "s\($0.startTime.bitPattern)-\($0.endTime.bitPattern)@\($0.speedFactor.bitPattern)" }
        let freezes = p.freezes.map { "f\($0.atTime.bitPattern)@\($0.holdDuration.bitPattern)" }
        // Only a video overlay's own composition track matters here — its
        // start/duration/mediaStart/file decide where and how much media gets
        // inserted. Rect, opacity and fades only affect the video composition
        // (rebuilt unconditionally below), never the track structure, so they
        // must not be in this key or every drag would tear down the player item.
        let overlays = p.overlays.filter { $0.kind == .video }
            .map { "o\($0.id)|\($0.fileName)|\($0.startTime.bitPattern)|\($0.duration.bitPattern)|\($0.mediaStart.bitPattern)" }
        return (cuts + speeds + freezes + overlays).joined(separator: "|") + (planner.hasCamera ? "|cam" : "")
    }

    /// Rebuilds the preview. Keeps the current item unless the timeline's
    /// structure changed.
    func rebuild(forceItem: Bool = false) {
        let project = document.project
        let key = topologyKey()
        let needsComposition = !project.cuts.isEmpty || !project.speeds.isEmpty || !project.freezes.isEmpty
            || planner.hasCamera || VideoRenderPlanner.hasVideoOverlays(project: project)
        let resumeTime = requestedSourceTime ?? currentSourceTime
        do {
            if needsComposition {
                let processed = try planner.processed(project: project, from: 0, to: document.duration, includeAudio: true)
                let composition = try planner.videoComposition(project: project, processed: processed,
                    options: previewOptions, onTrackReady: { [weak self] in self?.scheduleRebuild(item: false) })
                if key != topology || !usesComposition || forceItem || player.currentItem == nil {
                    replaceItem(asset: processed.composition, composition: composition,
                                mapping: VideoTimelineMapping(entries: processed.timeMap), resumeAt: resumeTime)
                    usesComposition = true
                    topology = key
                } else {
                    player.currentItem?.videoComposition = composition
                    refreshPausedFrame()
                }
            } else {
                guard let track = document.asset.tracks(withMediaType: .video).first else { return }
                let identity = [EffectsCompositionInstruction.TimeMapEntry(compStart: 0, compEnd: document.duration,
                                                                           sourceStart: 0, factor: 1)]
                let composition = try planner.sourceComposition(project: project, track: track, timeMap: identity,
                    options: previewOptions, onTrackReady: { [weak self] in self?.scheduleRebuild(item: false) })
                if usesComposition || forceItem || player.currentItem == nil {
                    replaceItem(asset: document.asset, composition: composition,
                                mapping: VideoTimelineMapping(entries: identity), resumeAt: resumeTime)
                    usesComposition = false
                    topology = key
                } else {
                    player.currentItem?.videoComposition = composition
                    refreshPausedFrame()
                }
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private var previewOptions: VideoRenderPlanner.Options {
        var o = options
        o.scale = previewScale
        return o
    }

    private func replaceItem(asset: AVAsset, composition: AVVideoComposition, mapping: VideoTimelineMapping,
                             resumeAt sourceTime: Double) {
        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        // Decode ahead generously: the compositor, not decoding, is the cost.
        item.preferredForwardBufferDuration = 2
        // Sped-up speech stays intelligible at the shuttle's faster rates.
        // `.timeDomain` is Apple's recommended algorithm for voice (`.spectral`
        // is tuned for music and costs more CPU for no benefit here).
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        self.mapping = mapping
        seekInFlight = false
        pendingSeek = nil
        let target = CMTime(seconds: mapping.compositionTime(at: sourceTime), preferredTimescale: 600_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        // Resume at the shuttle's actual rate (which may be a shuttle speed
        // or simulated reverse), not always a fresh 1x `player.play()`.
        if wasPlaying { applyShuttleRate() }
    }

    /// AVPlayer does not re-render a paused frame when only the composition
    /// changes; an exact seek to the same time does.
    private func refreshPausedFrame() {
        guard !isPlaying, let item = player.currentItem else { return }
        let time = item.currentTime()
        guard !seekInFlight else { pendingSeek = pendingSeek ?? time; return }
        seekInFlight = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.seekFinished() }
        }
    }

    // MARK: Clock

    private func tick(_ time: CMTime) {
        guard requestedSourceTime == nil else { return }
        let source = mapping.sourceTime(at: time.seconds)
        currentSourceTime = source
        let project = document.project
        if isPlaying, shuttle.rate > 0, source >= project.trimEnd - 0.0005 {
            currentSourceTime = project.trimEnd
            stopAtBoundary()
        } else if isPlaying, shuttle.rate < 0, source <= project.trimStart + 0.0005 {
            currentSourceTime = project.trimStart
            stopAtBoundary()
        }
        onTime?(currentSourceTime)
    }

    /// Playback ran into a trim boundary (forward at trimEnd, reverse at
    /// trimStart) — pause exactly like AVPlayer's own `actionAtItemEnd`, and
    /// keep the shuttle state in sync so the transport UI and HUD reflect it.
    private func stopAtBoundary() {
        player.pause()
        stopReverseTimer()
        shuttle.setDirectRate(0)
        onRateChange?(0)
        onPlayStateChange?(false)
    }

    /// Space: toggle play/pause. Decision (ROADMAP Phase 2): Space always
    /// normalizes to 1x forward rather than resuming the last shuttle rate —
    /// see `VideoPlaybackShuttle.toggleSpace()`'s doc comment.
    func togglePlay() { isPlaying ? pause() : play() }

    /// Plays forward at 1x. Also used internally as "resume normal playback"
    /// after cropping/scrubbing/text-editing pauses (none of those are J/K/L
    /// presses, so they don't touch the shuttle's K-chord timer).
    func play() { setDirectRate(1) }

    /// Pauses. Does not arm the K+L/K+J slow-motion chord window — only the
    /// literal K key (`pressK(at:)`) does that.
    func pause() { setDirectRate(0) }

    // MARK: J/K/L shuttle

    /// L: play forward, or step up the ladder (1x→2x→4x→8x) if already
    /// playing forward. K+L (K held) is the fixed slow-forward rate instead.
    func pressL(at timestamp: TimeInterval) {
        shuttle.pressL(at: timestamp)
        applyShuttleRate()
    }

    /// J: play in reverse, or step up the ladder if already reversing. K+J
    /// (K held) is the fixed slow-reverse rate instead. Reverse uses a
    /// negative `player.rate` when the item supports it; otherwise it's
    /// simulated by frame-stepping with the player paused (see
    /// `applyShuttleRate()`).
    func pressJ(at timestamp: TimeInterval) {
        shuttle.pressJ(at: timestamp)
        applyShuttleRate()
    }

    /// K: pause, and arm the K+L/K+J slow-motion chord window (a following
    /// L/J within `VideoPlaybackShuttle.chordWindow` is the slow rate instead
    /// of the normal ladder). AppKit's key-repeat delivers this "for free"
    /// while K is physically held — see the shuttle's doc comment.
    func pressK(at timestamp: TimeInterval) {
        shuttle.pressK(at: timestamp)
        applyShuttleRate()
    }

    /// Playback ▸ Play Speed menu: sets an exact rate directly (bypassing the
    /// ladder). 0 pauses.
    func setDirectRate(_ rate: Double) {
        shuttle.setDirectRate(rate)
        applyShuttleRate()
    }

    /// Playback ▸ Faster.
    func faster() {
        shuttle.faster()
        applyShuttleRate()
    }

    /// Playback ▸ Slower.
    func slower() {
        shuttle.slower()
        applyShuttleRate()
    }

    /// Maps `shuttle.rate` onto the player: a positive rate is a direct
    /// `player.rate` assignment (restarting from `trimStart` first if the
    /// playhead is outside the trim range, like the old `play()` did).
    /// Reverse first checks whether the current item can actually play
    /// backward at that rate (`AVPlayerItem.canPlayReverse` /
    /// `canPlayFastReverse` / `canPlaySlowReverse`); screen recordings
    /// commonly can't (reverse decoding predictive-coded H.264 is expensive),
    /// so the common case is the frame-stepping fallback, not the exception.
    private func applyShuttleRate() {
        let rate = shuttle.rate
        onRateChange?(rate)
        if rate >= 0 { stopReverseTimer() }
        switch rate {
        case 0:
            player.pause()
        case let r where r > 0:
            let project = document.project
            if currentSourceTime >= project.trimEnd - 0.05 || currentSourceTime < project.trimStart - 0.001 {
                seek(toSource: project.trimStart) { [weak self] in
                    guard let self else { return }
                    self.player.rate = Float(self.shuttle.rate)
                }
            } else {
                player.rate = Float(r)
            }
        default:
            if canPlayReverse(atRate: rate) {
                player.rate = Float(rate)
            } else {
                player.pause()
                startReverseTimer(rate: rate)
            }
        }
        onPlayStateChange?(isPlaying)
    }

    private func canPlayReverse(atRate rate: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        if rate < -1 { return item.canPlayFastReverse }
        if rate == -1 { return item.canPlayReverse }
        return item.canPlaySlowReverse
    }

    /// Frame-stepping fallback for reverse rates the item can't play
    /// natively. Ticks at 30Hz and moves enough frames per tick to
    /// approximate real-time playback at `abs(rate)`×. Seeks are exact
    /// (`seek(toSource:)`), which coalesces rapid calls, so at high fallback
    /// rates on a heavy composition this can lag behind true real-time —
    /// documented limitation, verify by hand at 4x/8x reverse on a real take.
    private func startReverseTimer(rate: Double) {
        stopReverseTimer()
        let tickInterval = 1.0 / 30.0
        let frameSeconds = max(document.frameDuration.seconds, 1.0 / 240)
        let framesPerTick = max(1, Int((tickInterval * abs(rate) / frameSeconds).rounded()))
        reverseTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepReverseTick(frames: framesPerTick) }
        }
    }

    private func stopReverseTimer() {
        reverseTimer?.invalidate()
        reverseTimer = nil
    }

    private func stepReverseTick(frames: Int) {
        let project = document.project
        let delta = document.frameDuration.seconds * Double(frames)
        let next = currentSourceTime - delta
        if next <= project.trimStart + 0.0005 {
            seek(toSource: project.trimStart)
            stopAtBoundary()
            return
        }
        seek(toSource: next)
    }

    /// Seeks exactly; rapid calls (scrubbing) coalesce to the latest target.
    func seek(toSource time: Double, completion: (() -> Void)? = nil) {
        let clamped = min(max(0, time), document.duration)
        requestedSourceTime = clamped
        currentSourceTime = clamped
        onTime?(clamped)
        let target = CMTime(seconds: mapping.compositionTime(at: clamped), preferredTimescale: 600_000)
        if seekInFlight {
            pendingSeek = target
            pendingCompletion = completion ?? pendingCompletion
            return
        }
        seekInFlight = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                completion?()
                self?.seekFinished()
            }
        }
    }

    private var pendingCompletion: (() -> Void)?

    private func seekFinished() {
        seekInFlight = false
        if let next = pendingSeek {
            pendingSeek = nil
            let completion = pendingCompletion
            pendingCompletion = nil
            seekInFlight = true
            player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    completion?()
                    self?.seekFinished()
                }
            }
            return
        }
        requestedSourceTime = nil
    }

    func step(frames: Int) {
        pause()
        let delta = document.frameDuration.seconds * Double(frames)
        let project = document.project
        seek(toSource: min(project.trimEnd, max(project.trimStart, currentSourceTime + delta)))
    }

    /// Composition-clock time for a source-asset time, via the mapping the
    /// current player item was built with — the same clock an overlay's
    /// keyframes animate on (`VideoOverlaySegment`'s doc comment). Exposed
    /// for `VideoKeyframeEditing.overlayLocalTime`.
    func compositionTime(forSource t: Double) -> Double { mapping.compositionTime(at: t) }

    /// The inverse of `compositionTime(forSource:)`, for seeking the
    /// playhead to a given overlay-local (output) time.
    func sourceTime(forComposition t: Double) -> Double { mapping.sourceTime(at: t) }

    /// Source time → edited (output) time for display.
    func outputTime(forSource t: Double) -> Double {
        let pieces = VideoRenderPlanner.pieces(project: document.project, from: document.project.trimStart,
                                               to: document.project.trimEnd)
        var elapsed = 0.0
        for piece in pieces {
            if piece.kind == .freeze {
                if t > piece.srcStart { elapsed += piece.compositionDuration }
                continue
            }
            if t >= piece.srcEnd { elapsed += piece.compositionDuration; continue }
            if t > piece.srcStart { elapsed += (t - piece.srcStart) / max(piece.factor, 0.0001) }
            break
        }
        return elapsed
    }
}
