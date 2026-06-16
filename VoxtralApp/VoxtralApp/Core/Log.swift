import Foundation

// Zero-cost unless VOXTRAL_LOG=1 is set in the launching process's environment
// (set by bin/voxlog, not bin/vox). Appends timestamped lines to /tmp/voxtral_app.log.
let isVerboseLogging = ProcessInfo.processInfo.environment["VOXTRAL_LOG"] == "1"

private let logFileURL = URL(fileURLWithPath: "/tmp/voxtral_app.log")

func vlog(_ message: @autoclosure () -> String) {
    guard isVerboseLogging else { return }
    let line = "[\(Date().timeIntervalSince1970)] \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: logFileURL.path) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? data.write(to: logFileURL)
    }
}
