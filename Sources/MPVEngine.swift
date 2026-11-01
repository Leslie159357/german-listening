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

@_silgen_name("mpv_request_log_messages")
private func c_mpv_request_log_messages(_ ctx: OpaquePointer?, _ level: UnsafePointer<CChar>) -> Int32

@_silgen_name("mpv_free")
private func c_mpv_free(_ data: UnsafeMutableRawPointer?)

@_silgen_name("mpv_terminate_destroy")
private func c_mpv_terminate_destroy(_ ctx: OpaquePointer?)

/// High-frequency playback position, split out of MPVEngine so 5 Hz ticks do not
/// invalidate every view that observes the engine.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let kind: String        // audio / sub / video
    let language: String
    let title: String
    let codec: String
    let isSelected: Bool

    var label: String {
        var parts: [String] = []
        if !language.isEmpty { parts.append(language.uppercased()) }
        if !title.isEmpty { parts.append(title) }
        if parts.isEmpty { parts.append(kind == "audio" ? "音轨 \(id)" : "字幕 \(id)") }
        if !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

enum EngineState: String {
    case idle, loading, playing, paused, failed
}

/// Control-plane wrapper around libmpv.
/// The video surface is an MPVRenderView created on top of `rawHandle`; nothing is loaded
/// until that surface reports a live render context, otherwise vo=libmpv has no context and
/// playback starts with audio only.
@MainActor
final class MPVEngine: ObservableObject {
    @Published private(set) var state: EngineState = .idle
    let clock = PlaybackClock()
    var time: Double { clock.time }
    @Published private(set) var duration: Double = 0
    @Published private(set) var lastError: String?

    nonisolated(unsafe) private(set) var rawHandle: UnsafeMutableRawPointer?

    private var ctx: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "xyz.1122275.mpv.poll", qos: .utility)
    private var pendingSeek: Double?

    private var rendererReady = false
    private var pendingLoad: (url: URL, start: Double)?
    private var detachHandler: (() -> Void)?
    nonisolated(unsafe) private var shuttingDown = false

    init() {
        configureAudioSession()
        ctx = c_mpv_create()
        guard let ctx else {
            state = .failed
            lastError = "mpv_create returned nil"
            return
        }
        _ = setOption("idle", "yes")
        _ = setOption("terminal", "no")
        _ = setOption("config", "no")
        _ = setOption("vo", "libmpv")          // render API consumer; "gpu" has no iOS context
        _ = setOption("gpu-api", "opengl")
        _ = setOption("ao", "audiounit")
        // VideoToolbox hands mpv an already-converted texture on this GLES path, and the
        // colour matrix/range lands wrong (measured: bt.709 8-bit H.264 shifted, software
        // decode correct). Software decode is the safe default; the wrench menu can opt in.
        _ = setOption("hwdec", "no")
        // iPhone screen recordings are often HDR (BT.2020/PQ). Forcing a 100-nit target crushed
        // the midtones; let mpv tonemap to a normal SDR reference white instead.
        _ = setOption("tone-mapping", "auto")
        _ = setOption("target-peak", "203")
        _ = setOption("target-colorspace-hint", "no")
        _ = setOption("dither-depth", "8")
        _ = setOption("audio-pitch-correction", "yes")
        _ = setOption("hr-seek", "yes")
        _ = c_mpv_request_log_messages(ctx, "warn")

        let rc = c_mpv_initialize(ctx)
        if rc < 0 {
            state = .failed
            lastError = errorText("mpv_initialize", rc)
            return
        }
        rawHandle = UnsafeMutableRawPointer(ctx)
        Self.sharedHandle = ctx
    }

    // MARK: - Renderer handshake

    /// Called by the surface so shutdown can free the render context first.
    func registerRenderer(detach: @escaping () -> Void) {
        detachHandler = detach
    }

    func rendererDidBecomeReady() {
        rendererReady = true
        if let pending = pendingLoad {
            pendingLoad = nil
            performLoad(url: pending.url, startAt: pending.start)
        }
    }

    func reportRenderFailure(_ reason: String) {
        lastError = "渲染层: \(reason)"
    }

    func load(url: URL, startAt: Double = 0) {
        guard ctx != nil else { return }
        guard rendererReady else {
            pendingLoad = (url, startAt)
            state = .loading
            return
        }
        performLoad(url: url, startAt: startAt)
    }

    /// `start=` is a loadfile option (mpv 0.35+): no seek-before-FILE_LOADED race.
    private func performLoad(url: URL, startAt: Double) {
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

    /// Frees the render context first, then drains the poll queue before destroying the core.
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        detachHandler?()
        detachHandler = nil

        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        pollQueue.sync {}          // let an in-flight get_property finish

        if let ctx {
            c_mpv_terminate_destroy(ctx)
            self.ctx = nil
        }
        rawHandle = nil
        Self.sharedHandle = nil
        state = .idle
    }

    // MARK: - Options / commands

    @discardableResult
    private func setOption(_ name: String, _ value: String) -> Int32 {
        guard let ctx else { return -1 }
        return name.withCString { n in value.withCString { v in c_mpv_set_option_string(ctx, n, v) } }
    }

    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let ctx else { return -1 }
        let pointers = args.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = pointers.compactMap { pointer in pointer.map { UnsafePointer($0) } }
        argv.append(nil)
        return argv.withUnsafeBufferPointer { buffer in c_mpv_command(ctx, buffer.baseAddress) }
    }

    private func setProperty(_ name: String, _ value: String) -> Int32 {
        guard let ctx else { return -1 }
        return name.withCString { n in value.withCString { v in c_mpv_set_property_string(ctx, n, v) } }
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

    func play() { if setProperty("pause", "no") >= 0 { state = .playing } }
    func pause() { if setProperty("pause", "yes") >= 0 { state = .paused } }
    func togglePlay() { state == .paused ? play() : pause() }

    func seek(to seconds: Double) {
        clock.time = seconds
        let rc = command(["seek", String(format: "%.3f", seconds), "absolute+exact"])
        if rc < 0 { pendingSeek = seconds }
    }

    // MARK: - Runtime switches (for narrowing down colour / performance issues on device)

    func setHardwareDecoding(_ enabled: Bool) {
        let rc = setProperty("hwdec", enabled ? "videotoolbox" : "no")
        AppLog.shared.log("硬解 → \(enabled ? "开" : "关") rc=\(rc)")
    }

    func setToneMapping(_ mode: String, targetPeak: Int = 203) {
        _ = setProperty("tone-mapping", mode)
        _ = setProperty("target-peak", String(targetPeak))
        AppLog.shared.log("音调映射 → \(mode)，target-peak=\(targetPeak)")
    }

    /// Dumps what mpv thinks the source is; distinguishes HDR/colour-space issues from channel swaps.
    func logVideoParameters() {
        let keys = ["video-params/primaries", "video-params/gamma", "video-params/colormatrix",
                    "video-params/sig-peak", "video-params/max-luma", "video-params/colorlevels",
                    "video-params/pixelformat", "video-params/hw-pixelformat",
                    "video-params/w", "video-params/h", "hwdec-current", "video-codec"]
        let summary = keys.map { "\($0)=\(Self.readPropertyString($0) ?? "-")" }.joined(separator: " ")
        AppLog.shared.log("视频参数 " + summary)
    }

    nonisolated(unsafe) static var sharedHandle: OpaquePointer?

    private static func readPropertyString(_ name: String) -> String? {
        guard let handle = sharedHandle else { return nil }
        return readProperty(handle, name)
    }

    /// mpv-native A/B loop: boundary precision comes from the decoder, not from a 5 Hz poll.
    func setLoop(start: Double, end: Double) {
        _ = setProperty("ab-loop-a", String(format: "%.3f", start))
        _ = setProperty("ab-loop-b", String(format: "%.3f", end))
        AppLog.shared.log("循环 \(String(format: "%.2f", start))–\(String(format: "%.2f", end))")
    }

    func clearLoop() {
        _ = setProperty("ab-loop-a", "no")
        _ = setProperty("ab-loop-b", "no")
    }

    // MARK: - Track selection (Multi-Audio / Multi-Subs containers)

    /// Reads mpv's track-list. Called after file-loaded, so every track is already enumerated.
    func readTracks() -> [MediaTrack] {
        guard let handle = MPVEngine.sharedHandle else { return [] }
        guard let countText = Self.readProperty(handle, "track-list/count"),
              let count = Int(countText), count > 0 else { return [] }
        var tracks: [MediaTrack] = []
        for index in 0..<count {
            func field(_ name: String) -> String {
                Self.readProperty(handle, "track-list/\(index)/\(name)") ?? ""
            }
            let kind = field("type")
            guard kind == "audio" || kind == "sub" else { continue }
            guard let id = Int(field("id")) else { continue }
            tracks.append(MediaTrack(id: id,
                                     kind: kind,
                                     language: field("lang"),
                                     title: field("title"),
                                     codec: field("codec"),
                                     isSelected: field("selected") == "yes"))
        }
        return tracks
    }

    func select(track: MediaTrack) {
        _ = setProperty(track.kind == "audio" ? "aid" : "sid", String(track.id))
        AppLog.shared.log("切换\(track.kind == "audio" ? "音轨" : "字幕轨") → \(track.label)")
    }

    func disableSubtitles() {
        _ = setProperty("sid", "no")
        AppLog.shared.log("关闭内置字幕轨")
    }

    func readAudioChain() -> String {
        guard let handle = MPVEngine.sharedHandle else { return "-" }
        let keys = ["aid", "sid", "current-ao", "audio-codec-name", "audio-params/channel-count"]
        return keys.map { "\($0)=\(Self.readProperty(handle, $0) ?? "-")" }.joined(separator: " ")
    }

    func setSpeed(_ speed: Double) {
        _ = setProperty("speed", String(format: "%.2f", max(0.25, min(4.0, speed))))
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil, let handle = ctx else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self, !self.shuttingDown else { return }
            let pos = Self.readProperty(handle, "time-pos").flatMap(Double.init)
            let dur = Self.readProperty(handle, "duration").flatMap(Double.init)
            let paused = Self.readProperty(handle, "pause") == "true"
            DispatchQueue.main.async {
                guard !self.shuttingDown else { return }
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
        if let pos { clock.time = pos }
        if let newDuration, newDuration > 0 { duration = newDuration }
        if let pendingSeek, clock.time > 0 {
            _ = command(["seek", String(format: "%.3f", pendingSeek), "absolute+exact"])
            self.pendingSeek = nil
        }
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
