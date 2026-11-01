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
    @State private var report: LibraryStore.ImportReport?

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("还没有素材", systemImage: "waveform")
                    } description: {
                        Text("从相册选视频；字幕文件（.srt/.vtt）可以单独导入，会自动挂到同名素材上")
                    } actions: {
                        Button("从相册导入视频") { showPhotosPicker = true }
                            .buttonStyle(.borderedProminent)
                        Button("导入文件（视频/字幕）") { showFileImporter = true }
                            .buttonStyle(.bordered)
                    }
                }
                ForEach(store.items) { item in
                    Button { selected = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            HStack(spacing: 8) {
                                Text(item.sentences.isEmpty ? "无字幕" : "\(item.sentences.count) 句")
                                    .font(.caption)
                                    .foregroundStyle(item.sentences.isEmpty ? .orange : .secondary)
                                if let sub = item.subtitleName {
                                    Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
                Section {
                    Text(buildLabel).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("精听库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showPhotosPicker = true } label: { Label("从相册导入视频", systemImage: "photo.on.rectangle") }
                        Button { showFileImporter = true } label: { Label("导入文件（视频/字幕）", systemImage: "folder") }
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
                    var report = LibraryStore.ImportReport()
                    for item in items {
                        if let movie = try? await item.loadTransferable(type: MovieTransfer.self) {
                            let partial = store.importSelection([movie.url])
                            report.media += partial.media
                            report.failures += partial.failures
                        } else {
                            report.failures.append("相册视频读取失败")
                        }
                    }
                    photoSelection = []
                    busy = false
                    self.report = report
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    report = store.importSelection(urls)
                case .failure(let error):
                    var failed = LibraryStore.ImportReport()
                    failed.failures = ["选择文件失败：\(error.localizedDescription)"]
                    report = failed
                }
            }
            .alert("导入结果", isPresented: Binding(get: { report != nil },
                                                 set: { if !$0 { report = nil } })) {
                Button("好", role: .cancel) { report = nil }
            } message: {
                Text(report?.summary ?? "")
            }
            .navigationDestination(item: $selected) { item in
                PlayerView(item: item).environmentObject(store)
            }
        }
    }

    private var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "版本 \(version) (build \(build))"
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
