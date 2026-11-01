import Foundation
import Combine

// libmpv C surface, statically linked through MPVKit. No bridging header: declare what we call.
@_silgen_name("mpv_create")
private func c_mpv_create() -> OpaquePointer?

@_silgen_name("mpv_initialize")
private func c_mpv_initialize(_ ctx: OpaquePointer?) -> Int32

@_silgen_name("mpv_set_option_string")
private func c_mpv_set_option_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_command_string")
private func c_mpv_command_string(_ ctx: OpaquePointer?, _ command: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_get_property_string")
private func c_mpv_get_property_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("mpv_free")
private func c_mpv_free(_ data: UnsafeMutableRawPointer?)

@_silgen_name("mpv_terminate_destroy")
private func c_mpv_terminate_destroy(_ ctx: OpaquePointer?)

/// Control-plane wrapper around libmpv.
/// v0.1 deliberately does not own a render surface: audio-only playback + exact clock.
enum EngineState: String {
    case idle, loading, playing, paused, failed
}

@MainActor
final class MPVEngine: ObservableObject {
    @Published private(set) var state: EngineState = .idle
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0

    private var ctx: OpaquePointer?
    private var ticker: Timer?

    init() {
        ctx = c_mpv_create()
        guard let ctx else { state = .failed; return }
        _ = setOption("idle", "yes")
        _ = setOption("terminal", "no")
        _ = setOption("config", "no")
        _ = setOption("vo", "null")          // render layer arrives in v0.2
        _ = setOption("ao", "audiounit")
        _ = setOption("audio-pitch-correction", "yes")
        _ = setOption("hr-seek", "yes")
        if c_mpv_initialize(ctx) < 0 { state = .failed }
    }

    deinit {
        ticker?.invalidate()
        if let ctx { c_mpv_terminate_destroy(ctx) }
    }

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Int32 {
        guard let ctx else { return -1 }
        return name.withCString { n in value.withCString { v in c_mpv_set_option_string(ctx, n, v) } }
    }

    private func command(_ line: String) {
        guard let ctx else { return }
        _ = line.withCString { c_mpv_command_string(ctx, $0) }
    }

    private func property(_ name: String) -> String? {
        guard let ctx else { return nil }
        let value = name.withCString { c_mpv_get_property_string(ctx, $0) }
        defer { if let value { c_mpv_free(value) } }
        guard let value else { return nil }
        return String(cString: value)
    }

    func load(url: URL, startAt: Double = 0) {
        state = .loading
        command("loadfile \"\(url.path)\"")
        if startAt > 0 { command(String(format: "seek %.3f absolute+exact", startAt)) }
        command("set pause no")
        state = .playing
        startTicker()
    }

    func play() { command("set pause no"); state = .playing }
    func pause() { command("set pause yes"); state = .paused }
    func seek(to seconds: Double) {
        command(String(format: "seek %.3f absolute+exact", seconds))
        time = seconds
    }
    func setSpeed(_ speed: Double) { command(String(format: "set speed %.2f", speed)) }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        if let t = property("time-pos"), let value = Double(t) { time = value }
        if let d = property("duration"), let value = Double(d) { duration = value }
        if let p = property("pause"), p == "yes", state == .playing { state = .paused }
    }
}
