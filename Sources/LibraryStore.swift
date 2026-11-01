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
    @discardableResult
    func importSelection(_ urls: [URL]) -> [MediaItem] {
        var imported: [MediaItem] = []
        let mediaURLs = urls.filter { isMedia($0) }
        let subtitleURLs = urls.filter { isSubtitle($0) }

        for url in mediaURLs {
            do {
                if let item = try importMedia(from: url, candidates: subtitleURLs) {
                    imported.append(item)
                }
            } catch {
                lastError = "导入 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
            }
        }
        return imported
    }

    private func isMedia(_ url: URL) -> Bool { !isSubtitle(url) }

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

        // Subtitle pairing: picked set → sandbox folder → give up.
        var subtitleURL: URL?
        if let picked = candidates.first(where: { $0.deletingPathExtension().lastPathComponent == base }) {
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
        guard !media.isEmpty else { return }
        for url in media {
            _ = try? importMedia(from: url, candidates: subs)
        }
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
