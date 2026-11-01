import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var selected: MediaItem?
    @State private var busy = false

    private var importTypes: [UTType] {
        [.movie, .audio, .audiovisualContent, .text, .plainText]
    }

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有素材", systemImage: "waveform")
                    } description: {
                        Text("从相册选视频，或把视频和同名 .srt/.vtt 放进「文件」App 的「我的 iPhone → 精听」目录")
                    } actions: {
                        Button("从相册导入视频") { showPhotosPicker = true }
                            .buttonStyle(.borderedProminent)
                        Button("从文件导入") { showFileImporter = true }
                            .buttonStyle(.bordered)
                    }
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
                    Menu {
                        Button { showPhotosPicker = true } label: { Label("从相册导入视频", systemImage: "photo.on.rectangle") }
                        Button { showFileImporter = true } label: { Label("从文件导入", systemImage: "folder") }
                        Button { store.scanDocumentsFolder() } label: { Label("扫描「我的 iPhone → 精听」", systemImage: "arrow.clockwise") }
                    } label: {
                        Image(systemName: busy ? "hourglass" : "plus")
                    }
                }
            }
            .task {
                store.scanDocumentsFolder()
            }
            .photosPicker(isPresented: $showPhotosPicker,
                          selection: $photoSelection,
                          maxSelectionCount: 10,
                          matching: .videos)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                busy = true
                Task {
                    for item in items {
                        if let movie = try? await item.loadTransferable(type: MovieTransfer.self) {
                            _ = try? store.importMedia(from: movie.url, candidates: [])
                        }
                    }
                    photoSelection = []
                    busy = false
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: importTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): _ = store.importSelection(urls)
                case .failure(let error): store.lastError = error.localizedDescription
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

/// Copies the picked video out of the Photos sandbox into a temp file the store can import.
struct MovieTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let name = received.file.lastPathComponent
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("import-\(UUID().uuidString)-\(name)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieTransfer(url: destination)
        }
    }
}
