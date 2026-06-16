import Foundation

enum STTEvent {
    case token(String)  // full accumulated, Layer-2-substituted text for the session so far (not a delta)
    case eou            // VAD advisory end-of-utterance (see precedence rule below)
    case error(String)
}

// Manages the WebSocket connection to ws://127.0.0.1:{port}/stt.
// Sends binary PCM frames from AudioRecorder.
// Applies Layer-2 substitution (variant→canonical) against the accumulated
// session text — not per raw decode-token fragment, since a word can arrive
// split across multiple token frames and a fragment alone can never satisfy
// a \b...\b word-boundary match.
//
// onEvent is called on URLSession's background queue — callers must dispatch
// to @MainActor if they touch SwiftUI state.
//
// EOU handling (caller's responsibility — this client just forwards the event):
//   .eou is always advisory, including during a double-tap-locked recording —
//   only a deliberate tap (HotkeyManager) or hotkey release ever stops a session.
//   Caller locks pill tail dim→solid on .eou and keeps the session open.
final class STTClient: @unchecked Sendable {
    var onEvent: ((STTEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var layer2Map: [String: String] = [:]

    // Raw (unsubstituted) text accumulated for the current session. The STT
    // sidecar streams decode tokens (sess.step(max_decode_tokens: 4)), which
    // are model decode units, not whole words — a word can arrive split
    // across multiple token frames (e.g. "Len" + "go"). Layer 2's \b...\b
    // word-boundary match can only ever see a complete word, so substitution
    // must run against the growing accumulated buffer, not each raw fragment
    // in isolation.
    private var rawBuffer = ""

    func configure(layer2Map: [String: String]) {
        self.layer2Map = layer2Map
    }

    func connect(port: Int) {
        guard task == nil else { return }
        vlog("STTClient.connect: port=\(port)")
        rawBuffer = ""
        let url = URL(string: "ws://127.0.0.1:\(port)/stt")!
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    func send(_ pcmData: Data) {
        // Fire-and-forget: send failures surface on the next receive, which
        // routes them through onEvent(.error(...)).
        task?.send(.data(pcmData)) { _ in }
    }

    func disconnect() {
        vlog("STTClient.disconnect")
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Private

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // task == nil means disconnect() was called intentionally — exit silently.
                // Any other failure is a real connection error.
                if self.task != nil {
                    vlog("STTClient.receiveLoop: connection lost — \(error)")
                    self.onEvent?(.error("WebSocket connection lost"))
                }
                // Do not reschedule — session is over either way.
            case .success(let message):
                self.handleMessage(message)
                self.receiveLoop()
            }
        }
    }

    private struct Frame: Decodable {
        let type: String
        let text: String?
        let msg:  String?
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let json) = message,
              let data = json.data(using: .utf8),
              let frame = try? JSONDecoder().decode(Frame.self, from: data)
        else {
            onEvent?(.error("malformed frame"))
            return
        }
        switch frame.type {
        case "token":
            rawBuffer += frame.text ?? ""
            onEvent?(.token(applyLayer2(rawBuffer)))
        case "eou":   onEvent?(.eou)
        case "error": onEvent?(.error(frame.msg ?? "sidecar error"))
        default:      break   // unknown type — forward-compatible, silently skip
        }
    }

    private func applyLayer2(_ text: String) -> String {
        var result = text
        for (variant, canonical) in layer2Map {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: variant))\\b",
                options: .caseInsensitive
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: canonical)
        }
        return result
    }
}
