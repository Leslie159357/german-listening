import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var words: [WordEntry] = []
    @Published var lastError: String?

    private let fm = FileManager.default
    private var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var mediaDir: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    private var libraryURL: URL { documents.appendingPathComponent("library.json") }

    private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    private func isSubtitle(_ url: URL) -> Bool {
        Self.subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    private func isMedia(_ url: URL) -> Bool {
        !isSubtitle(url)
    }

    /// Case/space/punctuation-insensitive key, so a hand-renamed subtitle still pairs.
    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        return lowered.filter { $0.isLetter || $0.isNumber }
    }

    /// Handles a file handed over by another app (115, Files, AirDrop). The URL is
    /// security-scoped and dies with this call, so copy immediately.
    @discardableResult
    func handleIncoming(_ url: URL) -> MediaItem? {
        do {
            let item = try importMedia(from: url, candidates: [])
            AppLog.shared.log("外部打开 \(url.lastPathComponent) → \(item?.title ?? "-")")
            return item
        } catch {
            lastError = "接收文件失败：\(error.localizedDescription)"
            AppLog.shared.log("外部打开失败：\(error.localizedDescription)")
            return nil
        }
    }

    init() {
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        load()
        sanitizeSubtitleAssignments()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var schemaVersion: Int? = 1
        var items: [MediaItem]
        var words: [WordEntry]

        enum CodingKeys: String, CodingKey { case schemaVersion, items, words }

        init(items: [MediaItem], words: [WordEntry]) {
            self.items = items
            self.words = words
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            items = (try? container.decode([MediaItem].self, forKey: .items)) ?? []
            words = (try? container.decode([WordEntry].self, forKey: .words)) ?? []
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            items = snapshot.items
            words = snapshot.words
        } catch {
            // Never silently start empty: keep the damaged file so the data is recoverable.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = documents.appendingPathComponent("library.corrupt-\(stamp).json")
            try? fm.moveItem(at: libraryURL, to: backup)
            lastError = "库文件损坏，已备份为 \(backup.lastPathComponent)"
        }
    }

    private func save() {
        // Refuse to overwrite a non-empty library with an empty one (a failed load must not wipe data).
        if items.isEmpty, let existing = try? Data(contentsOf: libraryURL), existing.count > 64 { return }
        guard let data = try? JSONEncoder().encode(Snapshot(items: items, words: words)) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    // MARK: - Import

    /// Imports the selected URLs. Subtitles can be selected together with the media:
    /// iOS only grants security scope to the URLs the user actually picked, so a sibling
    /// subtitle file in the same folder is NOT readable unless it was selected too.
    struct ImportReport {
        var media = 0
        var attached = 0
        var unmatched = 0
        var failures: [String] = []
        var isEmpty: Bool { media == 0 && attached == 0 && failures.isEmpty }
        var summary: String {
            var parts: [String] = []
            if media > 0 { parts.append("导入 \(media) 个素材") }
            if attached > 0 { parts.append("挂上 \(attached) 条字幕") }
            if unmatched > 0 { parts.append("\(unmatched) 条字幕没找到同名素材") }
            parts.append(contentsOf: failures.prefix(3))
            return parts.isEmpty ? "没有可导入的文件" : parts.joined(separator: "，")
        }
    }

    @discardableResult
    func importSelection(_ urls: [URL]) -> ImportReport {
        var report = ImportReport()
        let mediaURLs = urls.filter { isMedia($0) }
        let subtitleURLs = urls.filter { isSubtitle($0) }

        for url in mediaURLs {
            do {
                if let item = try importMedia(from: url, candidates: subtitleURLs) {
                    report.media += 1
                    if item.subtitleName != nil { report.attached += 1 }
                }
            } catch {
                report.failures.append("\(url.lastPathComponent) 失败")
            }
        }

        // Subtitles picked on their own: attach to whatever they match, never drop them silently.
        if !subtitleURLs.isEmpty {
            for url in subtitleURLs {
                if !subtitleAlreadyUsed(url) {
                    if attachSubtitle(url) { report.attached += 1 } else { report.unmatched += 1 }
                }
            }
            repairSubtitleAssignments()
        }
        return report
    }

    private func subtitleAlreadyUsed(_ url: URL) -> Bool {
        items.contains { $0.subtitleName == url.lastPathComponent }
    }

    /// Copies a subtitle into the sandbox and points the best-matching item at it.
    @discardableResult
    private func attachSubtitle(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = mediaDir.appendingPathComponent(url.lastPathComponent)
        if !fm.fileExists(atPath: destination.path) {
            guard (try? fm.copyItem(at: url, to: destination)) != nil else { return false }
        }
        let subBase = destination.deletingPathExtension().lastPathComponent
        let open = items.indices
            .filter { items[$0].subtitleName == nil && items[$0].sentences.isEmpty }
            .map { (index: $0, base: items[$0].fileName) }
        guard let pick = SubtitleMatcher.bestMatch(subtitle: subBase, items: open) else {
            let near = open.filter { SubtitleMatcher.tier(media: $0.base, subtitle: subBase) != nil }
            AppLog.shared.log(near.isEmpty
                ? "字幕 \(destination.lastPathComponent) 没有同名素材，未挂载"
                : "字幕 \(destination.lastPathComponent) 同时命中 \(near.count) 个素材，未挂载")
            return false
        }
        let index = pick.index
        let parsed = (try? SubtitleParser.parse(url: destination)) ?? []
        items[index].subtitleName = destination.lastPathComponent
        items[index].sentences = SubtitleParser.sentences(from: parsed)
        save()
        return true
    }

    /// Delegates to `SubtitleMatcher`: tiered scoring, and ambiguity never resolves to a guess.
    static func subtitleMatches(mediaBase: String, subtitleBase: String) -> Bool {
        SubtitleMatcher.tier(media: mediaBase, subtitle: subtitleBase) != nil
    }

    private func subtitleNameInUse(_ name: String, excluding index: Int) -> Bool {
        items.enumerated().contains { $0.offset != index && $0.element.subtitleName == name }
    }

    private func bestMatch(forSubtitleNamed subBase: String) -> Int? {
        let candidates = items.indices.filter { index in
            let item = items[index]
            guard item.subtitleName == nil, item.sentences.isEmpty else { return false }
            return Self.subtitleMatches(mediaBase: item.title, subtitleBase: subBase)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Re-pairs items that still have no subtitle against files already on disk. Only items with
    /// neither a subtitle nor sentences are touched, and a subtitle can only serve one item.
    func repairSubtitleAssignments() {
        let subs = (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? []
        let subtitleFiles = subs.filter { isSubtitle($0) }
        guard !subtitleFiles.isEmpty else { return }
        var changed = false
        for index in items.indices {
            guard items[index].sentences.isEmpty, items[index].subtitleName == nil else { continue }
            let matches = subtitleFiles.filter { candidate in
                Self.subtitleMatches(mediaBase: items[index].fileName,
                                     subtitleBase: candidate.deletingPathExtension().lastPathComponent)
                    && !subtitleNameInUse(candidate.lastPathComponent, excluding: index)
            }
            guard matches.count == 1, let hit = matches.first else { continue }
            let parsed = (try? SubtitleParser.parse(url: hit)) ?? []
            let sentences = SubtitleParser.sentences(from: parsed)
            guard !sentences.isEmpty else { continue }
            items[index].subtitleName = hit.lastPathComponent
            items[index].sentences = sentences
            changed = true
            AppLog.shared.log("配对 \(hit.lastPathComponent) → \(items[index].title)，\(sentences.count) 句")
        }
        if changed { save() }
    }

    /// Copies media into the sandbox and attaches a matching subtitle from the same selection.
    /// Only an unambiguous match is accepted — see `subtitleMatches`.
    @discardableResult
    func importMedia(from url: URL, candidates: [URL]) throws -> MediaItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let destination = mediaDir.appendingPathComponent(name)
        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.copyItem(at: url, to: destination)
                AppLog.shared.log("已复制 \(name) → Media")
            } catch {
                AppLog.shared.log("复制失败 \(name)：\(error.localizedDescription)")
                throw error
            }
        }

        let base = (name as NSString).deletingPathExtension
        if let existing = items.firstIndex(where: { $0.fileName == name }), !items[existing].sentences.isEmpty {
            return items[existing]     // already imported with a subtitle; do not disturb it
        }

        var subtitleName: String?
        var sentences: [Sentence] = []
        let scored = candidates.compactMap { url -> (url: URL, tier: SubtitleMatcher.Tier)? in
            guard let tier = SubtitleMatcher.tier(media: base,
                                                  subtitle: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (url, tier)
        }
        let bestTier = scored.map(\.tier).min()
        let matched = scored.filter { $0.tier == bestTier }.map(\.url)
        if matched.count == 1, let subURL = matched.first {
            let subScoped = subURL.startAccessingSecurityScopedResource()
            defer { if subScoped { subURL.stopAccessingSecurityScopedResource() } }
            let subDestination = mediaDir.appendingPathComponent(subURL.lastPathComponent)
            if !fm.fileExists(atPath: subDestination.path) {
                try? fm.copyItem(at: subURL, to: subDestination)
            }
            let cues = (try? SubtitleParser.parse(url: subDestination)) ?? []
            sentences = SubtitleParser.sentences(from: cues)
            if !sentences.isEmpty { subtitleName = subDestination.lastPathComponent }
            AppLog.shared.log("字幕 \(subDestination.lastPathComponent)：\(cues.count) 条 cue → \(sentences.count) 句")
        } else if matched.count > 1 {
            AppLog.shared.log("字幕匹配到 \(matched.count) 个候选，跳过自动挂载")
        }

        if let existing = items.firstIndex(where: { $0.fileName == name }) {
            items[existing].subtitleName = subtitleName
            items[existing].sentences = sentences
            save()
            return items[existing]
        }

        let item = MediaItem(title: base, fileName: name, subtitleName: subtitleName, sentences: sentences)
        items.append(item)
        save()
        AppLog.shared.log("入库 \(base)，当前 \(items.count) 条")
        return item
    }

    /// Drops attachments created by the old "only one subtitle around" rule, which glued a single
    /// subtitle onto unrelated videos.
    func sanitizeSubtitleAssignments() {
        var changed = false
        for index in items.indices {
            guard let sub = items[index].subtitleName else { continue }
            let subBase = (sub as NSString).deletingPathExtension
            // Only undo clear violations — a name that cannot belong to this media — and leave
            // everything else untouched so a user's own renaming is never silently destroyed.
            if !Self.subtitleMatches(mediaBase: items[index].fileName, subtitleBase: subBase) {
                AppLog.shared.log("解除不匹配的字幕：\(sub) ≠ \(items[index].title)")
                items[index].subtitleName = nil
                items[index].sentences = []
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Manual subtitle binding (in-player import)

    func item(_ id: UUID) -> MediaItem? { items.first { $0.id == id } }

    /// Explicit user choice beats any guessing: the subtitle is stored under the media's own
    /// basename so later launches keep the exact pairing, and replaces whatever was attached.
    @discardableResult
    func assignSubtitle(_ url: URL, to itemID: UUID) -> Int {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return 0 }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "srt" : url.pathExtension
        let mediaBase = (items[index].fileName as NSString).deletingPathExtension
        let destination = mediaDir.appendingPathComponent("\(mediaBase).\(ext)")
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        do {
            try fm.copyItem(at: url, to: destination)
        } catch {
            AppLog.shared.log("字幕复制失败：\(error.localizedDescription)")
            lastError = "字幕复制失败：\(error.localizedDescription)"
            return 0
        }

        let cues = (try? SubtitleParser.parse(url: destination)) ?? []
        let sentences = SubtitleParser.sentences(from: cues)
        guard !sentences.isEmpty else {
            AppLog.shared.log("字幕 \(destination.lastPathComponent) 解析出 0 句")
            lastError = "这份字幕解析不出句子（格式可能不受支持）"
            return 0
        }
        items[index].subtitleName = destination.lastPathComponent
        items[index].sentences = sentences
        save()
        AppLog.shared.log("手动挂载 \(destination.lastPathComponent) → \(items[index].title)，\(sentences.count) 句")
        return sentences.count
    }

    func removeSubtitle(from itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if let name = items[index].subtitleName {
            let path = mediaDir.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
            AppLog.shared.log("移除字幕 \(name)")
        }
        items[index].subtitleName = nil
        items[index].sentences = []
        save()
    }

    func scanDocumentsFolder() {
        guard let entries = try? fm.contentsOfDirectory(at: documents,
                                                        includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return }
        let mediaExts: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "ts", "webm", "mp3", "m4a", "wav", "flac", "aac", "ogg"]
        let subtitleExts: Set<String> = ["srt", "vtt", "ass", "ssa"]
        let media = entries.filter { mediaExts.contains($0.pathExtension.lowercased()) }
        let subs = entries.filter { subtitleExts.contains($0.pathExtension.lowercased()) }
        for url in media {
            _ = try? importMedia(from: url, candidates: subs)
        }
        if !subs.isEmpty { repairSubtitleAssignments() }
    }

    func mediaURL(for item: MediaItem) -> URL {
        mediaDir.appendingPathComponent(item.fileName)
    }

    func updatePosition(_ itemID: UUID, position: Double) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].lastPosition = position
        save()
    }

    func addWord(_ word: String, sentence: String, mediaID: UUID, position: Double) {
        words.append(WordEntry(word: word, sentence: sentence, mediaID: mediaID, position: position))
        save()
    }

    func sentence(at time: Double, in item: MediaItem) -> (index: Int, sentence: Sentence)? {
        guard !item.sentences.isEmpty else { return nil }
        let index = item.sentences.lastIndex(where: { $0.start <= time }) ?? 0
        return (index, item.sentences[index])
    }
}
