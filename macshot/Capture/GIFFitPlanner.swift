import Foundation

/// Limits a GIF must satisfy. The defaults are Cloudflare Images' animated
/// image limits: 10 MB per file and 50 megapixels of animation summed over
/// all frames (frames x width x height).
struct GIFFitBudget: Sendable, Equatable {
    var maxBytes: Int64 = 10_000_000
    var maxTotalPixels: Int64 = 50_000_000
    /// Smallest long edge the planner will step down to.
    var minLongEdge: Int = 640
    /// Output frame rates, best first.
    var fpsLadder: [Int] = [15, 12, 10, 8]
    /// Multiplier applied to the long edge for each size step (0 < step < 1).
    var longEdgeStep: Double = 0.85

    nonisolated static let cloudflareImages = GIFFitBudget()
}

/// One setting combination to try: output cadence and (even) pixel size.
struct GIFFitRung: Sendable, Equatable {
    let fps: Int
    let width: Int
    let height: Int
    var longEdge: Int { max(width, height) }

    /// User-facing summary of the settings, e.g. "12 fps, 960 px".
    nonisolated var summary: String { "\(fps) fps, \(longEdge) px" }
}

/// Pure planner for GIF auto-fit: which settings to try, and in what order.
///
/// **Order.** Readability matters more than smoothness for screen recordings,
/// and the two knobs are not equally costly: dropping 15 to 8 fps costs about
/// 47% of the bytes while only making motion choppier, whereas each x0.85 size
/// step saves about 28% and blurs text. So the plan keeps the starting size
/// and walks the fps ladder down first (15, 12, 10, 8). Only when even the
/// lowest fps does not fit does it step the size down, and from then on it
/// holds fps at that lowest rung: size N+1 at a higher fps than a failed
/// (8 fps, size N) rung would need more bytes than that failed rung, so it can
/// only fail again and each attempt is a full encode. Rungs are emitted only
/// if their fps is no higher than any earlier rung's. The last rung is always
/// exactly `minLongEdge` (the floor) at the lowest fps.
///
/// **Pixel budget.** A rung is dropped without being tried when its nominal
/// frame count (`ceil(duration x fps)`; holds that merge unchanged frames are
/// ignored, so this is conservative) times width x height exceeds
/// `maxTotalPixels`. If no size at an earlier fps passes, the first size that
/// does pass is entered at its highest passing fps, then the rule above applies.
///
/// **Sizes.** Never upscaled beyond the start size; each step multiplies the
/// long edge by `longEdgeStep`, rounded to an even number (GIF itself allows
/// odd sizes but the compositor and common encoders prefer even), and the short
/// edge follows the aspect ratio, also even.
enum GIFFitPlanner {
    nonisolated static func plan(duration: Double, startWidth: Int, startHeight: Int,
                                 startFPS: Int, budget: GIFFitBudget = .cloudflareImages) -> [GIFFitRung] {
        guard duration.isFinite, duration > 0, startWidth > 0, startHeight > 0, startFPS > 0,
              budget.longEdgeStep > 0, budget.longEdgeStep < 1 else { return [] }
        let fpsSteps = Array(Set(budget.fpsLadder.filter { $0 > 0 && $0 < startFPS } + [startFPS])).sorted(by: >)

        var rungs: [GIFFitRung] = []
        var ceiling = Int.max
        for (width, height) in sizes(startWidth: startWidth, startHeight: startHeight, budget: budget) {
            for fps in fpsSteps where fps <= ceiling {
                guard fitsPixelBudget(duration: duration, fps: fps, width: width, height: height, budget: budget)
                else { continue }
                rungs.append(GIFFitRung(fps: fps, width: width, height: height))
                ceiling = fps
            }
        }
        return rungs
    }

    /// Nominal animated area: `ceil(duration x fps)` frames at full size.
    nonisolated static func fitsPixelBudget(duration: Double, fps: Int, width: Int, height: Int,
                                            budget: GIFFitBudget) -> Bool {
        let frames = max(1, Int64((duration * Double(fps) - 1e-6).rounded(.up)))
        let (area, overflow) = (Int64(width) * Int64(height)).multipliedReportingOverflow(by: frames)
        return !overflow && area <= budget.maxTotalPixels
    }

    /// Start size first, then descending steps ending exactly at the floor.
    nonisolated static func sizes(startWidth: Int, startHeight: Int, budget: GIFFitBudget) -> [(Int, Int)] {
        let aspect = Double(min(startWidth, startHeight)) / Double(max(startWidth, startHeight))
        let landscape = startWidth >= startHeight
        func size(longEdge: Int) -> (Int, Int) {
            let long = longEdge, short = max(2, evenRounded(Double(longEdge) * aspect))
            return landscape ? (long, short) : (short, long)
        }
        let start = max(2, max(startWidth, startHeight) / 2 * 2)
        let floor = min(start, max(2, evenRounded(Double(budget.minLongEdge), up: true)))
        var edges = [start]
        while let last = edges.last, last > floor {
            let next = evenRounded(Double(last) * budget.longEdgeStep)
            edges.append(max(floor, min(next, last - 2)))
        }
        return edges.map { size(longEdge: $0) }
    }

    nonisolated private static func evenRounded(_ value: Double, up: Bool = false) -> Int {
        let half = up ? (value / 2).rounded(.up) : (value / 2).rounded()
        return Int(half) * 2
    }
}
