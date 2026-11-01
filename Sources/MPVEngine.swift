import Foundation
import AVFoundation
import Combine

// libmpv C surface, statically linked through MPVKit. No bridging header: declare what we call.
@_silgen_name("mpv_create")
private func c_mpv_create() -> OpaquePointer?

@_silgen_name("mpv_initialize")
private func c_mpv_initialize(_ ctx: OpaquePointer?) -> Int32

@_silgen_name("mpv_set_option_string")
private func c_mpv_set_option_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_set_property_string")
private func c_mpv_set_property_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_command")
private func c_mpv_command(_ ctx: OpaquePointer?, _ args: UnsafePointer<UnsafePointer<CChar>?>?) -> Int32

@_silgen_name("mpv_get_property_string")
private func c_mpv_get_property_string(_ ctx: OpaquePointer?, _ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("mpv_error_string")
private func c_mpv_error_string(_ error: Int32) -> UnsafePointer<CChar>?

@_silgen_name("mpv_free")
private func c_mpv_free(_ data: UnsafeMutableRawPointer?)

@_silgen_name("mpv_terminate_destroy")
private func c_mpv_terminate_destroy(_ ctx: OpaquePointer?)

enum EngineState: String {
    case idle, loading, playing, paused, failed
}

/// Control-plane wrapper around libmpv.
/// v0.1 has no render surface: audio-only playback plus an exact clock.
@MainActor
final class MPVEngine: ObservableObject {
    @Published private(set) var state: EngineState = .idle
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var lastError: String?

    private var ctx: OpaquePointer?

    /// Raw mpv_handle for the render surface; nil once shut down.
    nonisolated(unsafe) private(set) var rawHandle: UnsafeMutableRawPointer?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "xyz.1122275.mpv.poll", qos: .utility)
    private var pendingSeek: Double?

    init() {
        configureAudioSession()
        ctx = c_mpv_create()
        guard let ctx else { state = .failed; lastError = "mpv_create returned nil"; return }
        rawHandle = UnsafeMutableRawPointer(ctx)
        _ = setOption("idle", "yes")
        _ = setOption("terminal", "no")
        _ = setOption("config", "no")
        _ = setOption("vo", "gpu")           // rendered by MPVRenderView through the render API
        _ = setOption("gpu-api", "opengl")
        _ = setOption("ao", "audiounit")
        _ = setOption("audio-pitch-correction", "yes")
        _ = setOption("hr-seek", "yes")
        let rc = c_mpv_initialize(ctx)
        if rc < 0 {
            state = .failed
            lastError = errorText("mpv_initialize", rc)
        }
    }

    /// Timer.invalidate and mpv_terminate_destroy must both run on the thread that owns the runloop.
    func shutdown() {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        if let ctx {
            c_mpv_terminate_destroy(ctx)
            self.ctx = nil
            rawHandle = nil
        }
        state = .idle
    }

    // MARK: - Options / commands

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Int32 {
        guard let ctx else { return -1 }
        return name.withCString { n in value.withCString { v in c_mpv_set_option_string(ctx, n, v) } }
    }

    /// Array form: no string escaping problems with paths containing quotes or backslashes.
    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let ctx else { return -1 }
        var pointers = args.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = pointers.compactMap { pointer in
            pointer.map { UnsafePointer($0) }
        }
        argv.append(nil)
        return argv.withUnsafeBufferPointer { buffer in
            c_mpv_command(ctx, buffer.baseAddress)
        }
    }

    private func setProperty(_ name: String, _ value: String) -> Int32 {
        guard let ctx else { return -1 }
        return name.withCString { n in value.withCString { v in c_mpv_set_property_string(ctx, n, v) } }
    }

    private func readProperty(_ name: String) -> String? {
        guard let ctx else { return nil }
        let value = name.withCString { c_mpv_get_property_string(ctx, $0) }
        defer { if let value { c_mpv_free(value) } }
        guard let value else { return nil }
        return String(cString: value)
    }

    private func errorText(_ what: String, _ rc: Int32) -> String {
        let message = c_mpv_error_string(rc).map { String(cString: $0) } ?? "error \(rc)"
        return "\(what): \(message)"
    }

    private func fail(_ what: String, _ rc: Int32) {
        state = .failed
        lastError = errorText(what, rc)
    }

    // MARK: - Transport

    /// `start=` is a loadfile option (mpv 0.35+): the file opens at that position,
    /// avoiding the "seek before FILE_LOADED is dropped" race of seek-after-loadfile.
    func load(url: URL, startAt: Double = 0) {
        if ctx == nil { return }
        state = .loading
        lastError = nil
        let rc = command(["loadfile", url.path, "replace", "0", String(format: "start=%.3f", max(0, startAt))])
        if rc < 0 {
            fail("loadfile", rc)
            return
        }
        _ = setProperty("pause", "no")
        state = .playing
        startPolling()
    }

    func play() {
        if setProperty("pause", "no") >= 0 { state = .playing }
    }

    func pause() {
        if setProperty("pause", "yes") >= 0 { state = .paused }
    }

    func togglePlay() {
        state == .paused ? play() : pause()
    }

    func seek(to seconds: Double) {
        time = seconds
        let rc = command(["seek", String(format: "%.3f", seconds), "absolute+exact"])
        if rc < 0 { pendingSeek = seconds }   // retry once the file reports loaded
    }

    func reportRenderFailure(_ reason: String) {
        lastError = "渲染层: \(reason)"
    }

    func setSpeed(_ speed: Double) {
        _ = setProperty("speed", String(format: "%.2f", max(0.25, min(4.0, speed))))
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil, let handle = ctx else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pos = Self.readProperty(handle, "time-pos").flatMap(Double.init)
            let dur = Self.readProperty(handle, "duration").flatMap(Double.init)
            let paused = Self.readProperty(handle, "pause") == "true"
            DispatchQueue.main.async {
                self.apply(pos: pos, duration: dur, paused: paused)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    nonisolated private static func readProperty(_ handle: OpaquePointer, _ name: String) -> String? {
        let value = name.withCString { c_mpv_get_property_string(handle, $0) }
        defer { if let value { c_mpv_free(value) } }
        guard let value else { return nil }
        return String(cString: value)
    }

    private func apply(pos: Double?, duration newDuration: Double?, paused: Bool) {
        if let pos { time = pos }
        if let newDuration, newDuration > 0 { duration = newDuration }
        if let pendingSeek, time > 0 {
            _ = command(["seek", String(format: "%.3f", pendingSeek), "absolute+exact"])
            self.pendingSeek = nil
        }
        // state follows mpv, never the optimistic button press
        if paused, state == .playing { state = .paused }
        if !paused, state == .paused || state == .loading { state = .playing }
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
    }
}
