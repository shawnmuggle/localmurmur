import Foundation
import CSherpaOnnx

/// Local offline ASR using sherpa-onnx SenseVoice.
/// The recognizer (model) is loaded once at startup and reused across sessions.
/// Audio is accumulated during a PTT session, then decoded in one shot on release.
public class SherpaRecognizer: @unchecked Sendable {
    public var onStatus: ((ASRStatus) -> Void)?
    public var onResult: ((ASRResult) -> Void)?

    private let recognizer: OpaquePointer
    private let lock = NSLock()

    // True-silence cutoff on PEAK amplitude (normalized [-1,1]). Speech peaks well
    // above this; ambient room noise stays below. Lower than a mean-RMS gate so
    // short, quiet words survive.
    private static let silencePeakThreshold: Float = 0.05

    // Silence padding added around the utterance before offline decode (16kHz).
    // 0.1s lead + 0.4s tail keeps boundary tokens from being clipped.
    private static let leadPadSamples = 1600   // 0.1s
    private static let tailPadSamples = 6400   // 0.4s

    // Accumulated Float32 audio for the current session
    private var audioBuffer: [Float] = []
    private var sessionActive = false

    public init?(modelDir: String, numThreads: Int = 2) {
        // Prefer the full-precision model when present, otherwise the int8 quant.
        // This makes switching precision a no-code operation: drop model.onnx in to
        // use fp32, delete it to fall back to model.int8.onnx.
        let fp32Path = (modelDir as NSString).appendingPathComponent("model.onnx")
        let int8Path = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        let fm = FileManager.default
        let modelPath = fm.fileExists(atPath: fp32Path) ? fp32Path : int8Path
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")

        guard fm.fileExists(atPath: modelPath) else {
            fputs("[SherpaRecognizer] model not found in \(modelDir)\n", stderr)
            return nil
        }
        fputs("[SherpaRecognizer] using model: \((modelPath as NSString).lastPathComponent)\n", stderr)

        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = UnsafePointer(strdup(modelPath))
        config.model_config.sense_voice.language = UnsafePointer(strdup("auto"))
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = UnsafePointer(strdup(tokensPath))
        config.model_config.num_threads = Int32(numThreads)
        config.model_config.provider = UnsafePointer(strdup("cpu"))
        config.model_config.debug = 0
        config.decoding_method = UnsafePointer(strdup("greedy_search"))

        guard let rec = SherpaOnnxCreateOfflineRecognizer(&config) else {
            fputs("[SherpaRecognizer] failed to create offline recognizer\n", stderr)
            return nil
        }
        self.recognizer = rec
        fputs("[SherpaRecognizer] SenseVoice model loaded from \(modelDir)\n", stderr)
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Start a new recognition session (just resets the audio buffer).
    public func startSession() {
        lock.lock()
        audioBuffer.removeAll(keepingCapacity: true)
        sessionActive = true
        lock.unlock()
        fputs("[SherpaRecognizer] session started\n", stderr)
    }

    /// Feed raw Int16 PCM audio (16kHz mono). Accumulated for offline decode.
    public func sendAudio(_ data: Data) {
        let floats = int16ToFloat(data)
        lock.lock()
        audioBuffer.append(contentsOf: floats)
        lock.unlock()
    }

    /// Signal end of audio — runs offline decode and emits final result.
    /// Callbacks are dispatched back to the main thread to avoid data races.
    public func finishAudio() {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        sessionActive = false
        let samples = audioBuffer
        audioBuffer.removeAll(keepingCapacity: true)
        lock.unlock()

        onStatus?(.processing)

        guard !samples.isEmpty else {
            fputs("[SherpaRecognizer] finishAudio: empty audio\n", stderr)
            onResult?(ASRResult(text: "", isFinal: true))
            return
        }

        // Skip recognition only on true silence/noise (→ hallucination). Use the
        // PEAK amplitude, not mean RMS: a short word surrounded by pre-roll/lead
        // silence has low mean RMS but a clear peak, and we must not drop it.
        var peak: Float = 0
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        if peak < Self.silencePeakThreshold {
            fputs("[SherpaRecognizer] finishAudio: audio too quiet (peak=\(String(format: "%.4f", peak))), skipping\n", stderr)
            onResult?(ASRResult(text: "", isFinal: true))
            return
        }

        let duration = Double(samples.count) / 16000.0
        fputs("[SherpaRecognizer] decoding \(String(format: "%.1f", duration))s audio (peak=\(String(format: "%.4f", peak)))...\n", stderr)

        // Pad the utterance with silence on both ends before decoding. SenseVoice's
        // fbank front-end + CTC tail can drop the first/last token when speech starts
        // at sample 0 or ends abruptly; a short silence margin lets the boundary
        // tokens emit cleanly. Padding is silence, so it never adds spurious words.
        let leadSilence = [Float](repeating: 0, count: Self.leadPadSamples)
        let tailSilence = [Float](repeating: 0, count: Self.tailPadSamples)
        let paddedSamples = leadSilence + samples + tailSilence

        // Run offline decode on a background thread to avoid blocking the caller.
        // Dispatch callbacks back to main thread to avoid data races on closure properties.
        let rec = recognizer
        Thread.detachNewThread { [weak self] in
            guard let stream = SherpaOnnxCreateOfflineStream(rec) else {
                fputs("[SherpaRecognizer] failed to create offline stream\n", stderr)
                DispatchQueue.main.async { self?.onResult?(ASRResult(text: "", isFinal: true)) }
                return
            }
            defer { SherpaOnnxDestroyOfflineStream(stream) }

            paddedSamples.withUnsafeBufferPointer { buf in
                SherpaOnnxAcceptWaveformOffline(stream, 16000, buf.baseAddress, Int32(buf.count))
            }
            SherpaOnnxDecodeOfflineStream(rec, stream)

            let resultPtr = SherpaOnnxGetOfflineStreamResult(stream)
            let text = resultPtr?.pointee.text.map { String(cString: $0) } ?? ""
            if let r = resultPtr { SherpaOnnxDestroyOfflineRecognizerResult(r) }

            fputs("[SherpaRecognizer] result: \(text)\n", stderr)
            DispatchQueue.main.async {
                self?.onResult?(ASRResult(text: text, isFinal: true))
                self?.onStatus?(.done)
            }
        }
    }

    /// Stop the current session without decoding.
    public func stopSession() {
        lock.lock()
        sessionActive = false
        audioBuffer.removeAll(keepingCapacity: true)
        lock.unlock()
        onStatus?(.idle)
    }

    // MARK: - Private

    private func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(samples[$0]) / 32768.0 }
        }
    }
}
