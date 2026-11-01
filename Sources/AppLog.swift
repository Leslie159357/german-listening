import Foundation

/// On-screen event log. Every import step writes here so a screenshot is enough to diagnose.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("app.log")
    }()

    private init() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = text.split(separator: "\n").suffix(60).map(String.init)
        }
        log("启动 build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
    }

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = "\(stamp) \(message)"
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        append(line)
    }

    private func append(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
