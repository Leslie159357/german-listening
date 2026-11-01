import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showImporter = false
    @State private var selected: MediaItem?

    private var importTypes: [UTType] {
        [.movie, .audio, .audiovisualContent, .text, .plainText]
    }

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView("还没有素材",
                                           systemImage: "waveform",
                                           description: Text("选中视频和同名 .srt/.vtt 一起导入（可多选）"))
                }
                ForEach(store.items) { item in
                    Button { selected = item } label: {
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
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    _ = store.importSelection(urls)
                case .failure(let error):
                    store.lastError = error.localizedDescription
                }
            }
            .alert("出错了", isPresented: Binding(get: { store.lastError != nil },
                                               set: { if !$0 { store.lastError = nil } })) {
                Button("好", role: .cancel) { store.lastError = nil }
            } message: {
                Text(store.lastError ?? "")
            }
            .navigationDestination(item: $selected) { item in
                PlayerView(item: item).environmentObject(store)
            }
        }
    }
}
