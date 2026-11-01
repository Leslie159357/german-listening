import SwiftUI

struct PlayerView: View {
    let item: MediaItem
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var engine = MPVEngine()

    @State private var currentIndex = 0
    @State private var loopSentence = false
    @State private var speed: Double = 1.0
    @State private var lastSeekAt = Date.distantPast

    private var sentences: [Sentence] { item.sentences }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            currentSentenceCard
            controls
            sentenceList
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.load(url: store.mediaURL(for: item), startAt: item.lastPosition)
            syncIndex()
        }
        .onDisappear {
            store.updatePosition(item.id, position: engine.time)
            engine.pause()
        }
        .onChange(of: engine.time) { _, newValue in
            syncIndex(time: newValue)
            enforceLoop(time: newValue)
        }
    }

    private var statusBar: some View {
        HStack {
            Text(String(format: "%.2f / %.2f", engine.time, max(engine.duration, engine.time)))
                .font(.caption.monospacedDigit())
            Spacer()
            Text(engine.state.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var currentSentenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sentences.indices.contains(currentIndex) ? sentences[currentIndex].text : "—")
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let translation = sentences.indices.contains(currentIndex) ? sentences[currentIndex].translation : nil {
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
                Button { togglePlay() } label: {
                    Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                }
                Button { loopSentence.toggle() } label: {
                    Image(systemName: loopSentence ? "repeat.1.circle.fill" : "repeat.1.circle")
                }
                Button { jump(1) } label: { Image(systemName: "chevron.right.2") }
            }
            .font(.title3)
            .buttonStyle(.bordered)

            HStack {
                Text("0.5×").font(.caption2)
                Slider(value: $speed, in: 0.5...1.5, step: 0.05) { _ in
                    engine.setSpeed(speed)
                }
                Text("1.5×").font(.caption2)
                Text(String(format: "%.2f×", speed)).font(.caption.monospacedDigit())
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var sentenceList: some View {
        List {
            ForEach(Array(sentences.enumerated()), id: \.element.id) { index, sentence in
                HStack(alignment: .top, spacing: 8) {
                    Text(String(format: "%.1f", sentence.start))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(sentence.text).font(.subheadline)
                        .foregroundStyle(index == currentIndex ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { jumpTo(index) }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    private func togglePlay() {
        if engine.state == .paused { engine.play() } else { engine.pause() }
    }

    private func jump(_ delta: Int) { jumpTo(currentIndex + delta) }

    private func jumpTo(_ index: Int) {
        guard sentences.indices.contains(index) else { return }
        currentIndex = index
        seek(to: sentences[index].start)
    }

    private func seek(to time: Double) {
        lastSeekAt = Date()
        engine.seek(to: time)
    }

    private func syncIndex(time: Double? = nil) {
        guard !sentences.isEmpty else { return }
        let now = time ?? engine.time
        if let found = store.sentence(at: now, in: item)?.index, found != currentIndex {
            currentIndex = found
        }
    }

    /// Re-entrancy guard: mpv fires time updates while a seek is still settling.
    private func enforceLoop(time: Double) {
        guard loopSentence, sentences.indices.contains(currentIndex) else { return }
        guard Date().timeIntervalSince(lastSeekAt) > 0.15 else { return }
        let sentence = sentences[currentIndex]
        if time >= sentence.end || time < sentence.start - 0.3 {
            seek(to: sentence.start)
        }
    }
}
