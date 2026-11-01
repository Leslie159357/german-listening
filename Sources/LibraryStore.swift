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

    init() {
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        load()
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
        guard let index = bestMatch(forSubtitleNamed: destination.deletingPathExtension().lastPathComponent) else {
            return false
        }
        let parsed = (try? SubtitleParser.parse(url: destination)) ?? []
        items[index].subtitleName = destination.lastPathComponent
        items[index].sentences = SubtitleParser.sentences(from: parsed)
        save()
        return true
    }

    private func bestMatch(forSubtitleNamed subBase: String) -> Int? {
        let key = Self.normalized(subBase)
        if let exact = items.firstIndex(where: { Self.normalized($0.title) == key }) { return exact }
        if let prefix = items.firstIndex(where: { item in
            let itemKey = Self.normalized(item.title)
            return itemKey.hasPrefix(key) || key.hasPrefix(itemKey)
        }) { return prefix }
        return items.count == 1 ? 0 : nil
    }

    /// Re-pairs every item that still has no subtitle against what is on disk.
    func repairSubtitleAssignments() {
        let subs = (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? []
        let subtitleFiles = subs.filter { isSubtitle($0) }
        guard !subtitleFiles.isEmpty else { return }
        var changed = false
        for index in items.indices where items[index].sentences.isEmpty {
            let key = Self.normalized(items[index].title)
            let hit = subtitleFiles.first { Self.normalized($0.deletingPathExtension().lastPathComponent) == key }
                ?? subtitleFiles.first { candidate in
                    let cand = Self.normalized(candidate.deletingPathExtension().lastPathComponent)
                    return !cand.isEmpty && (cand.hasPrefix(key) || key.hasPrefix(cand))
                }
                ?? (subtitleFiles.count == 1 ? subtitleFiles.first : nil)
            guard let hit else { continue }
            let parsed = (try? SubtitleParser.parse(url: hit)) ?? []
            let sentences = SubtitleParser.sentences(from: parsed)
            guard !sentences.isEmpty else { continue }
            items[index].subtitleName = hit.lastPathComponent
            items[index].sentences = sentences
            changed = true
        }
        if changed { save() }
    }

    private func isMedia(_ url: URL) -> Bool { !isSubtitle(url) }

    /// Case/space/punctuation-insensitive key, so a hand-renamed subtitle still pairs.
    static func normalized(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        return lowered.filter { $0.isLetter || $0.isNumber }
    }

    private func isSubtitle(_ url: URL) -> Bool {
        ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased())
    }

    /// Copies media into the sandbox. Subtitles are looked up in the picked set first, then in Documents/Media.
    @discardableResult
    func importMedia(from url: URL, candidates: [URL] = []) throws -> MediaItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let base = url.deletingPathExtension().lastPathComponent

        let destination = mediaDir.appendingPathComponent(name)
        if !fm.fileExists(atPath: destination.path) {
            try fm.copyItem(at: url, to: destination)
        }

        // Subtitle pairing: exact name → prefix name → the only subtitle around → give up.
        var subtitleURL: URL?
        let key = Self.normalized(base)
        let matched = candidates.first { Self.normalized($0.deletingPathExtension().lastPathComponent) == key }
            ?? candidates.first { candidate in
                let cand = Self.normalized(candidate.deletingPathExtension().lastPathComponent)
                return !cand.isEmpty && (cand.hasPrefix(key) || key.hasPrefix(cand))
            }
            ?? (candidates.count == 1 ? candidates.first : nil)
        if let picked = matched {
            let scopedSub = picked.startAccessingSecurityScopedResource()
            defer { if scopedSub { picked.stopAccessingSecurityScopedResource() } }
            let dest = mediaDir.appendingPathComponent(picked.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: picked, to: dest) }
            subtitleURL = dest
        } else {
            for ext in ["srt", "vtt", "ass", "ssa"] {
                let candidate = mediaDir.appendingPathComponent(base).appendingPathExtension(ext)
                if fm.fileExists(atPath: candidate.path) { subtitleURL = candidate; break }
            }
        }

        var sentences: [Sentence] = []
        if let subtitleURL {
            sentences = SubtitleParser.sentences(from: (try? SubtitleParser.parse(url: subtitleURL)) ?? [])
        }

        // Re-import refreshes the existing entry (a subtitle added later must take effect).
        if let index = items.firstIndex(where: { $0.fileName == name }) {
            items[index].sentences = sentences
            items[index].subtitleName = subtitleURL?.lastPathComponent
            save()
            return items[index]
        }

        let item = MediaItem(title: base,
                             fileName: name,
                             subtitleName: subtitleURL?.lastPathComponent,
                             sentences: sentences)
        items.append(item)
        save()
        return item
    }

    /// Handles a file handed over by another app (115, Files, Mail, AirDrop).
    /// The URL is security-scoped and dies with this call, so copy immediately.
    @discardableResult
    func handleIncoming(_ url: URL) -> MediaItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try importMedia(from: url, candidates: [])
        } catch {
            lastError = "接收文件失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Picks up anything the user dropped into the app's Documents folder via the Files app,
    /// plus same-named subtitles, and imports it into the library.
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
