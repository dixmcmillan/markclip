import Foundation

/// A single parsed subtitle cue, before mapping onto the project's clock.
struct CaptionCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// Parses SRT and WebVTT text into cues, so captions produced by an
/// external tool (MacWhisper and friends) can be imported. Deliberately
/// format-agnostic: both formats boil down to "a timing line containing
/// `-->`, then one or more lines of text, until a blank line or the next
/// timing line" — everything else (SRT index numbers, the `WEBVTT` header,
/// `NOTE`/`STYLE` blocks, VTT cue identifiers, cue settings trailing the
/// timestamps) is simply ignored rather than specially recognized, which is
/// also what makes this robust to whatever a given tool actually emits.
enum CaptionImport {
    static func parse(_ rawText: String) -> [CaptionCue] {
        var text = rawText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        var cues: [CaptionCue] = []
        var i = 0
        while i < lines.count {
            guard let (start, end) = timing(in: lines[i]) else { i += 1; continue }
            i += 1
            var textLines: [String] = []
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if timing(in: line) != nil { break }  // back-to-back cues, no blank separator
                textLines.append(stripTags(line))
                i += 1
            }
            let cueText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty, end > start {
                cues.append(CaptionCue(start: start, end: end, text: cueText))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Decodes file data, stripping a UTF-8 BOM if present and falling back
    /// to Latin-1 if the bytes aren't valid UTF-8 (some tools emit that).
    static func parse(data: Data) -> [CaptionCue] {
        var bytes = data
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.count >= 3, Array(bytes.prefix(3)) == utf8BOM { bytes.removeFirst(3) }
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
        return parse(text)
    }

    private static func timing(in line: String) -> (Double, Double)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let startToken = parts[0].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
              let start = timestamp(String(startToken)), let end = timestamp(String(endToken)) else { return nil }
        return (start, end)
    }

    /// Accepts SRT's `HH:MM:SS,mmm`, WebVTT's `HH:MM:SS.mmm`, and WebVTT's
    /// hour-less `MM:SS.mmm` form.
    private static func timestamp(_ token: String) -> Double? {
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3, let seconds = Double(parts.last!) else { return nil }
        var hours = 0.0
        var minutes: Double
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
            hours = h
            minutes = m
        } else {
            guard let m = Double(parts[0]) else { return nil }
            minutes = m
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }
}
