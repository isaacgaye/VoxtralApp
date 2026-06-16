import AVFoundation
import Foundation

enum AudioRecorderError: Error {
    case permissionDenied
    case engineStart(Error)
}

// Mic → 16 kHz / 16-bit signed / mono PCM chunks.
// Format chosen to match mlx-audio / Voxtral input requirements.
//
// onBuffer is called on AVAudioEngine's internal audio thread.
// Callers must dispatch to their own queue if they need thread safety.
final class AudioRecorder {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!

    var onBuffer: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    func start() throws {
        guard !engine.isRunning else { return }

        // Gate on explicitly denied/restricted only — .notDetermined lets the engine
        // start and the OS shows its own permission dialog on first access.
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized || authStatus == .notDetermined else {
            throw AudioRecorderError.permissionDenied
        }

        // Read hardware format at start() time — not at init — because the engine
        // may not have resolved the input device until the graph is active.
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let targetRate = AudioRecorder.sampleRate
        let hwRate = hwFormat.sampleRate

        // AVAudioConverter handles sample-rate conversion + float32→int16 + stereo→mono
        // in one pass. Created once here, reused across all tap callbacks.
        let conv = AVAudioConverter(from: hwFormat, to: AudioRecorder.format)!
        converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter else { return }

            let outputFrameCapacity = AVAudioFrameCount(
                (Double(buffer.frameLength) * targetRate / hwRate).rounded(.up)
            )
            guard outputFrameCapacity > 0,
                  let outputBuffer = AVAudioPCMBuffer(
                      pcmFormat: AudioRecorder.format,
                      frameCapacity: outputFrameCapacity
                  ) else { return }

            // Single-input-consumed pattern: hand the input buffer to the converter
            // exactly once, then signal noDataNow on subsequent calls.
            var inputConsumed = false
            var convError: NSError?
            let status = conv.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status == .haveData,
                  outputBuffer.frameLength > 0,
                  let samples = outputBuffer.int16ChannelData else { return }

            // 2 bytes per Int16 sample; mono so channel 0 is the only channel.
            let data = Data(bytes: samples[0], count: Int(outputBuffer.frameLength) * 2)
            self.onBuffer?(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Clean up tap and converter so the recorder can be started again.
            inputNode.removeTap(onBus: 0)
            converter = nil
            throw AudioRecorderError.engineStart(error)
        }
    }

    func stop() {
        // removeTap and stop are both no-ops on an already-stopped engine with no tap.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Nil converter only after engine.stop() — ensures no tap callback is
        // running when we release it.
        converter = nil
    }
}
