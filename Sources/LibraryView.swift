import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var selected: MediaItem?

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView("还没有素材",
                                           systemImage: "waveform",
                                           description: Text("导入本地视频或音频，同名字幕会自动配对"))
                }
                ForEach(store.items) { item in
                    Button {
                        selected = item
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.sentences.isEmpty ? "无字幕" : "\(item.sentences.count) 句")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("精听库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.movie, .audio, .audiovisualContent],
                          allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    _ = try store.importMedia(from: url)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("导入失败", isPresented: Binding(get: { errorMessage != nil },
                                                  set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .navigationDestination(item: $selected) { item in
                PlayerView(item: item)
                    .environmentObject(store)
            }
        }
    }
}
