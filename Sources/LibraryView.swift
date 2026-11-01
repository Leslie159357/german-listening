import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var log = AppLog.shared

    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var selected: MediaItem?
    @State private var busy = false
    @State private var report: LibraryStore.ImportReport?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        present(picker: .photos)
                    } label: {
                        Label("从相册导入视频", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        present(picker: .files)
                    } label: {
                        Label("从文件导入（视频 / 字幕）", systemImage: "folder")
                    }
                    Button {
                        log.log("点击：扫描目录")
                        store.scanDocumentsFolder()
                        log.log("扫描完成，库内 \(store.items.count) 条")
                    } label: {
                        Label("扫描「我的 iPhone → 精听」", systemImage: "arrow.clockwise")
                    }
                }

                if store.items.isEmpty {
                    Section {
                        Text("还没有素材。字幕可以单独导入，会自动挂到同名素材上。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("素材") {
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
                    }
                }

                Section("事件日志（最近 12 条）") {
                    ForEach(Array(log.lines.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text(buildLabel).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("精听库")
            .task {
                let media = store.items.count
                log.log("进入首屏，库内 \(media) 条")
                store.scanDocumentsFolder()
            }
            .photosPicker(isPresented: $showPhotosPicker,
                          selection: $photoSelection,
                          maxSelectionCount: 10,
                          matching: .videos)
            .onChange(of: photoSelection) { _, items in
                log.log("相册选中 \(items.count) 项")
                guard !items.isEmpty else { return }
                busy = true
                Task {
                    var report = LibraryStore.ImportReport()
                    for item in items {
                        if let movie = try? await item.loadTransferable(type: MovieTransfer.self) {
                            log.log("相册文件落地：\(movie.url.lastPathComponent)")
                            let partial = store.importSelection([movie.url])
                            report.media += partial.media
                            report.failures += partial.failures
                        } else {
                            log.log("相册读取失败")
                            report.failures.append("相册视频读取失败")
                        }
                    }
                    photoSelection = []
                    busy = false
                    self.report = report
                    log.log("相册导入结束：\(report.summary)")
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                log.log("文件选择器回调触发")
                switch result {
                case .success(let urls):
                    log.log("选中 \(urls.count) 个文件")
                    for url in urls { log.log("  · \(url.lastPathComponent)") }
                    let outcome = store.importSelection(urls)
                    log.log("导入结果：\(outcome.summary)")
                    report = outcome
                case .failure(let error):
                    log.log("选择器失败：\(error.localizedDescription)")
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

    private enum PickerKind { case files, photos }

    /// Presenting straight out of a Button/Menu action can be swallowed by the dismissal
    /// animation; give the sheet one runloop turn of breathing room.
    private func present(picker: PickerKind) {
        log.log("点击：\(picker == .files ? "从文件导入" : "从相册导入")")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            switch picker {
            case .files: showFileImporter = true
            case .photos: showPhotosPicker = true
            }
            log.log("已请求弹出\(picker == .files ? "文件选择器" : "相册选择器")")
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
            try? FileManager.default.copyItem(at: received.file, to: destination)
            return MovieTransfer(url: destination)
        }
    }
}
