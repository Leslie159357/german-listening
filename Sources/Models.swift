import Foundation

struct Sentence: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
    var translation: String?

    var duration: Double { max(0.2, end - start) }
}

struct MediaItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var fileName: String
    var subtitleName: String?
    var addedAt: Date = Date()
    var lastPosition: Double = 0
    var sentences: [Sentence] = []
}

struct WordEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var word: String
    var sentence: String
    var mediaID: UUID
    var position: Double
    var createdAt: Date = Date()
}
