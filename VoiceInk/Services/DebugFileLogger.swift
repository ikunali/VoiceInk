import Foundation

#if LOCAL_BUILD
/// Writes timestamped log lines to ~/Library/Logs/VoiceInk/debug.log.
/// Only compiled in LOCAL_BUILD — never ships in production.
final class DebugFileLogger {
    static let shared = DebugFileLogger()

    private let fileHandle: FileHandle?
    let logURL: URL

    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/VoiceInk")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        logURL = logsDir.appendingPathComponent("debug.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logURL)
        fileHandle?.seekToEndOfFile()
        write("=== VoiceInk debug session started ===")
        write("Log file: \(logURL.path)")
    }

    func write(_ message: String, category: String = "General") {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}
#endif
