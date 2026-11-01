import Foundation

/// Decides whether a subtitle file belongs to a media file.
///
/// The rule that matters: a count of candidates never proves an identity. "There is only one
/// subtitle in the folder" is not evidence that it belongs to this video — that shortcut once
/// glued one Peppa subtitle onto every item in the library. Ambiguity resolves to *no match*,
/// never to a best guess.
enum SubtitleMatcher {

    /// Tier ordering, highest first. Higher wins; ties mean ambiguous.
    enum Tier: Int, Comparable {
        case exactName = 0          // normalised names identical
        case sameEpisode = 1        // same (season, episode) and overlapping titles
        case strippedNames = 2      // equal after language/quality labels are removed
        case prefix = 3             // one name is a prefix of the other, no digit in the residual

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue > rhs.rawValue }
    }

    struct Candidate {
        let index: Int
        let tier: Tier
    }

    // MARK: - Normalisation

    /// Two keys per name: umlauts folded to base letters, and umlauts expanded to ae/oe/ue.
    /// German releases use both spellings interchangeably (`Müller` / `Mueller`, `Straße` / `Strasse`).
    static func keys(_ name: String) -> Set<String> {
        let expanded = name
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "Ä", with: "Ae")
            .replacingOccurrences(of: "Ö", with: "Oe")
            .replacingOccurrences(of: "Ü", with: "Ue")
            .replacingOccurrences(of: "ß", with: "ss")
        return [squash(name), squash(expanded)]
    }

    /// Lowercase, strip diacritics, keep letters and digits only.
    static func squash(_ name: String) -> String {
        name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Word set used for the "same episode, similar title" tier.
    static func words(_ name: String) -> Set<String> {
        let stripped = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(String(stripped).split(separator: " ").map(String.init).filter { $0.count > 2 })
    }

    // MARK: - Episode numbers

    private static let episodePatterns: [String] = [
        #"(?i)s(\d{1,2})[ ._-]*e(\d{1,3})"#,
        #"(?i)(\d{1,2})x(\d{2,3})"#,
        #"(?i)folge[ ._-]*(\d{1,3})"#,
        #"第\s*(\d{1,3})\s*集"#
    ]

    /// Returns (season, episode); season is 1 when the pattern carries no season.
    static func episode(_ name: String) -> (season: Int, episode: Int)? {
        for pattern in episodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: range) else { continue }
            if match.numberOfRanges >= 3,
               let s = Int((name as NSString).substring(with: match.range(at: 1))),
               let e = Int((name as NSString).substring(with: match.range(at: 2))) {
                return (s, e)
            }
            if match.numberOfRanges >= 2,
               let e = Int((name as NSString).substring(with: match.range(at: 1))) {
                return (1, e)
            }
        }
        return nil
    }

    // MARK: - Label stripping

    private static let noiseWords: Set<String> = [
        "1080p", "2160p", "720p", "480p", "x264", "x265", "hevc", "h264", "aac", "ac3", "dts",
        "webrip", "web", "webdl", "bluray", "bdrip", "hdtv", "multi", "subs", "sub", "audio",
        "ger", "deu", "german", "deutsch", "eng", "english", "jpn", "japanese", "dual", "dl",
        "dragsterps", "srt", "vtt", "ass", "clean"
    ]

    static func stripped(_ name: String) -> String {
        var text = name
        // drop bracketed groups entirely — they are release tags, not titles
        while let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            text.removeSubrange(open...close)
        }
        let kept = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        let tokens = String(kept).split(separator: " ").map(String.init)
            .filter { !noiseWords.contains($0) && !$0.allSatisfy(\.isNumber) }
        return tokens.joined()
    }

    // MARK: - Scoring

    /// nil means "not a match"; ambiguity is handled by the caller.
    static func tier(media: String, subtitle: String) -> Tier? {
        let mediaKeys = keys(media)
        let subKeys = keys(subtitle)

        if !mediaKeys.isDisjoint(with: subKeys) { return .exactName }

        let mediaEpisode = episode(media)
        let subEpisode = episode(subtitle)
        if let m = mediaEpisode, let s = subEpisode {
            guard m == s else { return nil }            // different episodes never pair
            let shared = words(media).intersection(words(subtitle))
            let denominator = max(1, min(words(media).count, words(subtitle).count))
            if Double(shared.count) / Double(denominator) >= 0.5 { return .sameEpisode }
            return .sameEpisode                          // same episode + same show, accept
        }
        if mediaEpisode != nil || subEpisode != nil { return nil }

        let strippedMedia = stripped(media)
        let strippedSub = stripped(subtitle)
        if !strippedMedia.isEmpty, strippedMedia == strippedSub { return .strippedNames }

        for short in [squash(media), squash(subtitle)] {
            let long = short == squash(media) ? squash(subtitle) : squash(media)
            guard short.count >= 6, long.count > short.count, long.hasPrefix(short) else { continue }
            let residual = long.dropFirst(short.count)
            if residual.allSatisfy({ !$0.isNumber }) { return .prefix }
        }
        return nil
    }

    /// Picks the assignment for one subtitle among items that still have no subtitle.
    /// Returns nil when nothing matches or when the best tier is shared by more than one item.
    static func bestMatch(subtitle: String, items: [(index: Int, base: String)]) -> (index: Int, tier: Tier)? {
        let scored = items.compactMap { item -> (index: Int, tier: Tier)? in
            guard let tier = tier(media: item.base, subtitle: subtitle) else { return nil }
            return (item.index, tier)
        }
        guard let best = scored.map(\.tier).min() else { return nil }
        let winners = scored.filter { $0.tier == best }
        return winners.count == 1 ? winners[0] : nil
    }
}
