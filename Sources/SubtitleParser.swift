import Foundation

/// Minimal SRT / WebVTT parser. ASS is out of scope here: libass renders it directly.
enum SubtitleParser {

    static func parse(url: URL) throws -> [Sentence] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return parse(text: raw)
    }

    static func parse(text: String) -> [Sentence] {
        var cues: [Sentence] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimeLine(timeLine) else { continue }
            let body = lines
                .filter { $0 != timeLine && !$0.hasPrefix("WEBVTT") }
                .filter { Int($0) == nil }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            cues.append(Sentence(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseTimeLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let a = parts[0].trimmingCharacters(in: .whitespaces)
        let b = parts[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        guard let s = parseTimestamp(a), let e = parseTimestamp(b) else { return nil }
        return (s, e)
    }

    private static func parseTimestamp(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: ",", with: ".")
        let comps = cleaned.components(separatedBy: ":")
        var seconds: Double = 0
        switch comps.count {
        case 3:
            guard let h = Double(comps[0]), let m = Double(comps[1]), let s = Double(comps[2]) else { return nil }
            seconds = h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(comps[0]), let s = Double(comps[1]) else { return nil }
            seconds = m * 60 + s
        default:
            return nil
        }
        return seconds
    }

    /// Merge cues that are close together and split long ones, so a "sentence" is a spoken unit.
    static func sentences(from cues: [Sentence], mergeGap: Double = 0.25, maxLength: Double = 12) -> [Sentence] {
        var result: [Sentence] = []
        var current: Sentence?
        for cue in cues {
            guard var acc = current else { current = cue; continue }
            let gap = cue.start - acc.end
            let mergedLength = cue.end - acc.start
            if gap <= mergeGap && mergedLength <= maxLength {
                acc.end = max(acc.end, cue.end)
                acc.text += " " + cue.text
                current = acc
            } else {
                result.append(acc)
                current = cue
            }
        }
        if let last = current { result.append(last) }
        return result
    }
}
