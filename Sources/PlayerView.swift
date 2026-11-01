import SwiftUI

struct PlayerView: View {
    let item: MediaItem
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var engine = MPVEngine()

    @State private var currentIndex = 0
    @State private var loopTarget: Sentence?      // snapshot: the loop must not follow the playhead
    @State private var speed: Double = 1.0
    @State private var hasLoaded = false
    @State private var lastSeekAt = Date.distantPast

    private var sentences: [Sentence] { item.sentences }

    var body: some View {
        VStack(spacing: 0) {
            videoSurface
            statusBar
            currentSentenceCard
            controls
            SentenceListView(sentences: sentences,
                             currentIndex: currentIndex,
                             onSelect: { jumpTo($0) })
                .equatable()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("记录视频参数") { engine.logVideoParameters() }
                    Divider()
                    Button("硬解：开") { engine.setHardwareDecoding(true) }
                    Button("硬解：关") { engine.setHardwareDecoding(false) }
                    Divider()
                    Button("音调映射：自动") { engine.setToneMapping("auto") }
                    Button("音调映射：裁剪") { engine.setToneMapping("clip") }
                    Button("音调映射：关闭") { engine.setToneMapping("no") }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
        }
        .task(id: item.id) {
            guard !hasLoaded else { return }
            hasLoaded = true
            engine.load(url: store.mediaURL(for: item), startAt: item.lastPosition)
            syncIndex(time: item.lastPosition)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            engine.logVideoParameters()
        }
        .onDisappear {
            store.updatePosition(item.id, position: engine.time)
            engine.pause()
            engine.shutdown()
        }
        .onChange(of: engine.time) { _, newValue in
            syncIndex(time: newValue)
            enforceLoop(time: newValue)
        }
        .onChange(of: speed) { _, newValue in
            engine.setSpeed(newValue)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var videoSurface: some View {
        if let handle = engine.rawHandle {
            MPVSurface(handle: handle,
                       onReady: { engine.rendererDidBecomeReady() },
                       onFailure: { engine.reportRenderFailure($0) },
                       onDetach: { engine.registerRenderer(detach: $0) })
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
        } else {
            Rectangle().fill(Color.black).aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(Text("引擎未就绪").foregroundStyle(.white.secondary))
        }
    }

    private var statusBar: some View {
        HStack {
            Text(String(format: "%.2f / %.2f", engine.time, max(engine.duration, engine.time)))
                .font(.caption.monospacedDigit())
            Spacer()
            if let error = engine.lastError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(engine.state.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var currentSentenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentSentence?.text ?? "—")
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let translation = currentSentence?.translation {
                Text(translation).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                Button { jump(-1) } label: { Image(systemName: "chevron.left.2") }
                Button { engine.togglePlay() } label: {
                    Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                }
                Button { toggleLoop() } label: {
                    Image(systemName: loopTarget == nil ? "repeat.1.circle" : "repeat.1.circle.fill")
                }
                Button { jump(1) } label: { Image(systemName: "chevron.right.2") }
            }
            .font(.title3)
            .buttonStyle(.bordered)

            HStack {
                Text("0.5×").font(.caption2)
                Slider(value: $speed, in: 0.5...1.5, step: 0.05)
                Text("1.5×").font(.caption2)
                Text(String(format: "%.2f×", speed)).font(.caption.monospacedDigit())
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var currentSentence: Sentence? {
        sentences.indices.contains(currentIndex) ? sentences[currentIndex] : nil
    }

    // MARK: - Actions

    private func toggleLoop() {
        if loopTarget == nil {
            loopTarget = currentSentence
        } else {
            loopTarget = nil
        }
    }

    private func jump(_ delta: Int) { jumpTo(currentIndex + delta) }

    private func jumpTo(_ index: Int) {
        guard sentences.indices.contains(index) else { return }
        currentIndex = index
        if loopTarget != nil { loopTarget = sentences[index] }
        seek(to: sentences[index].start)
    }

    private func seek(to time: Double) {
        lastSeekAt = Date()
        engine.seek(to: time)
    }

    private func syncIndex(time: Double? = nil) {
        guard !sentences.isEmpty else { return }
        let now = time ?? engine.time
        if let found = sentences.lastIndex(where: { $0.start <= now }), found != currentIndex {
            currentIndex = found
        }
    }

    /// Compares against the snapshot taken when looping was enabled, not the live index:
    /// for back-to-back cues the live index has already advanced by the time the boundary is crossed.
    private func enforceLoop(time: Double) {
        guard let target = loopTarget else { return }
        guard Date().timeIntervalSince(lastSeekAt) > 0.15 else { return }
        if time >= target.end || time < target.start - 0.5 {
            seek(to: target.start)
        }
    }
}

/// Isolated from the 10 Hz clock updates: SwiftUI skips its diff while the index is unchanged.
struct SentenceListView: View, Equatable {
    let sentences: [Sentence]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    static func == (lhs: SentenceListView, rhs: SentenceListView) -> Bool {
        lhs.currentIndex == rhs.currentIndex
            && lhs.sentences.count == rhs.sentences.count
            && lhs.sentences.first?.id == rhs.sentences.first?.id
    }

    var body: some View {
        List {
            ForEach(Array(sentences.enumerated()), id: \.element.id) { index, sentence in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%.1f", sentence.start))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(sentence.text)
                        .font(.subheadline)
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(index) }
            }
        }
        .listStyle(.plain)
    }
}


/// Bridges the Objective-C render view into SwiftUI.
struct MPVSurface: UIViewRepresentable {
    let handle: UnsafeMutableRawPointer
    let onReady: () -> Void
    let onFailure: (String) -> Void
    let onDetach: (@escaping () -> Void) -> Void

    func makeUIView(context: Context) -> MPVRenderView {
        let view = MPVRenderView(frame: .zero, mpvHandle: handle)
        view.onReady = onReady
        view.onFailure = onFailure
        onDetach { [weak view] in view?.detachRenderer() }
        return view
    }

    func updateUIView(_ uiView: MPVRenderView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVRenderView, coordinator: ()) {
        uiView.detachRenderer()
    }
}
