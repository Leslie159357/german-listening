import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var words: [WordEntry] = []

    private let fm = FileManager.default
    private var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var mediaDir: URL { documents.appendingPathComponent("Media", isDirectory: true) }
    private var libraryURL: URL { documents.appendingPathComponent("library.json") }
    private var wordsURL: URL { documents.appendingPathComponent("words.json") }

    init() {
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var items: [MediaItem]
        var words: [WordEntry]
    }

    private func load() {
        if let data = try? Data(contentsOf: libraryURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            items = snapshot.items
            words = snapshot.words
        }
    }

    private func save() {
        let snapshot = Snapshot(items: items, words: words)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    // MARK: - Import

    /// Copies the media into the sandbox and pairs a same-named .srt/.vtt if present.
    @discardableResult
    func importMedia(from url: URL) throws -> MediaItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        if let existing = items.first(where: { $0.fileName == name }) { return existing }

        let destination = mediaDir.appendingPathComponent(name)
        if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: destination) }
        try fm.copyItem(at: url, to: destination)

        var sentences: [Sentence] = []
        var subtitleName: String?
        for ext in ["srt", "vtt"] {
            let candidate = url.deletingPathExtension().appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) {
                let subtitleDest = mediaDir.appendingPathComponent(candidate.lastPathComponent)
                if !fm.fileExists(atPath: subtitleDest.path) {
                    try? fm.copyItem(at: candidate, to: subtitleDest)
                }
                sentences = SubtitleParser.sentences(from: (try? SubtitleParser.parse(url: subtitleDest)) ?? [])
                subtitleName = candidate.lastPathComponent
                break
            }
        }

        let item = MediaItem(title: url.deletingPathExtension().lastPathComponent,
                             fileName: name,
                             subtitleName: subtitleName,
                             sentences: sentences)
        items.append(item)
        save()
        return item
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
        let entry = WordEntry(word: word, sentence: sentence, mediaID: mediaID, position: position)
        words.append(entry)
        save()
    }

    func sentence(at time: Double, in item: MediaItem) -> (index: Int, sentence: Sentence)? {
        guard !item.sentences.isEmpty else { return nil }
        let index = item.sentences.lastIndex(where: { $0.start <= time }) ?? 0
        return (index, item.sentences[index])
    }
}
