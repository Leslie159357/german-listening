import Foundation

/// Minimal SRT / WebVTT parser.
/// Line-oriented state machine: a cue starts at a line containing "-->", not at a blank-line block,
/// so files exported without blank separators still parse.
enum SubtitleParser {

    static func parse(url: URL) throws -> [Sentence] {
        parse(text: try readText(url))
    }

    /// Tries UTF-8 (with BOM stripping), then the encodings German/Chinese subtitle files actually use.
    static func readText(_ url: URL) throws -> String {
        if let data = try? Data(contentsOf: url) {
            for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
                if let text = String(data: data, encoding: encoding), !text.isEmpty {
                    return stripBOM(text)
                }
            }
        }
        var used: String.Encoding = .utf8
        let text = try String(contentsOf: url, usedEncoding: &used)
        return stripBOM(text)
    }

    static func stripBOM(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, first.value == 0xFEFF else { return text }
        return String(text.unicodeScalars.dropFirst())
    }

    static func parse(text: String) -> [Sentence] {
        let normalized = normalizeNewlines(stripBOM(text))
        var cues: [Sentence] = []
        var pendingStart: Double?
        var pendingEnd: Double?
        var body: [String] = []
        var indexLine: String?

        func flush() {
            defer {
                pendingStart = nil
                pendingEnd = nil
                body.removeAll()
                indexLine = nil
            }
            guard let start = pendingStart, let end = pendingEnd, end > start else { return }
            let text = body
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return }
            cues.append(Sentence(start: start, end: end, text: text))
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }

            if let (start, end) = parseTimeLine(line) {
                // A new timing line also closes the previous cue even without a blank line.
                if pendingStart != nil { flush() }
                pendingStart = start
                pendingEnd = end
                indexLine = nil
                continue
            }

            if pendingStart == nil {
                // Outside a cue: only tolerate a bare index or a "WEBVTT" header.
                if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") { continue }
                indexLine = line
                continue
            }

            if line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") { continue }
            body.append(line)
        }
        flush()

        return cues.sorted { $0.start < $1.start }
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func parseTimeLine(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let left = parts[0].trimmingCharacters(in: .whitespaces)
        let right = parts[1].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        guard let start = parseTimestamp(left), let end = parseTimestamp(right) else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ value: String) -> Double? {
        let cleaned = value.replacingOccurrences(of: ",", with: ".")
        let comps = cleaned.components(separatedBy: ":")
        switch comps.count {
        case 3:
            guard let h = Double(comps[0]), let m = Double(comps[1]), let s = Double(comps[2]) else { return nil }
            return h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(comps[0]), let s = Double(comps[1]) else { return nil }
            return m * 60 + s
        default:
            return nil
        }
    }

    /// Merge close cues into spoken units and split units that exceed maxLength at the last sentence end.
    static func sentences(from cues: [Sentence], mergeGap: Double = 0.25, maxLength: Double = 12) -> [Sentence] {
        var merged: [Sentence] = []
        var current: Sentence?

        for cue in cues {
            guard var acc = current else { current = cue; continue }
            let gap = cue.start - acc.end
            if gap <= mergeGap && (cue.end - acc.start) <= maxLength {
                acc.end = max(acc.end, cue.end)
                acc.text += " " + cue.text
                current = acc
            } else {
                merged.append(acc)
                current = cue
            }
        }
        if let last = current { merged.append(last) }

        // Long cues must not stay whole: a 30 s "sentence" makes single-sentence looping useless.
        return merged.flatMap { splitLong($0, maxLength: maxLength) }
    }

    private static func splitLong(_ sentence: Sentence, maxLength: Double) -> [Sentence] {
        guard sentence.end - sentence.start > maxLength else { return [sentence] }
        let pieces = sentence.text
            .components(separatedBy: CharacterSet(charactersIn: ".!?。！？"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard pieces.count > 1 else {
            // No punctuation: cut by equal time windows so the user still has usable units.
            let count = max(2, Int(ceil((sentence.end - sentence.start) / maxLength)))
            let step = (sentence.end - sentence.start) / Double(count)
            return (0..<count).map { index in
                Sentence(start: sentence.start + Double(index) * step,
                         end: sentence.start + Double(index + 1) * step,
                         text: "#\(index + 1)")
            }
        }
        let totalChars = pieces.reduce(0) { $0 + $1.count }
        let span = sentence.end - sentence.start
        var result: [Sentence] = []
        var cursorTime = sentence.start
        var consumedChars = 0
        for piece in pieces {
            let share = totalChars == 0 ? 1.0 : Double(piece.count) / Double(totalChars)
            let pieceDuration = span * share
            result.append(Sentence(start: cursorTime,
                                   end: min(sentence.end, cursorTime + pieceDuration),
                                   text: piece))
            cursorTime += pieceDuration
            consumedChars += piece.count
        }
        if let last = result.last, last.end < sentence.end {
            result[result.count - 1].end = sentence.end
        }
        return result
    }
}
