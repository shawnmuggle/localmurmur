@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

/// Microphone capture that keeps the engine **warm** between push-to-talk
/// sessions. Creating/starting a fresh AVAudioEngine on every key press costs
/// ~200-300ms of cold-start latency, during which the first (and, for very
/// short utterances, the *entire*) word is lost. Instead we start the engine
/// once and keep it running, continuously filling a small pre-roll ring buffer.
///
/// While idle, captured audio is only kept in the ring (not forwarded). On
/// `beginCapture()` we flush the ring — so the moment just *before* the key
/// press is included — then stream live until `endCapture()`. This makes even
/// a 0.2s press capture real audio.
///
/// Trade-off: the microphone stays active the whole time the engine runs, so
/// macOS shows the in-use (orange) indicator continuously.
public class AudioCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    public var onChunk: (@Sendable (Data) -> Void)?
    public var onDeviceName: (@Sendable (String) -> Void)?
    public private(set) var isRunning = false

    private let lock = NSLock()
    private var capturing = false
    private var preroll = Data()
    /// Pre-roll length: 0.3s @ 16kHz mono int16 = 9600 bytes.
    private static let prerollMaxBytes = 9600

    public init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
    }

    /// Start the engine and keep it running (warm). Safe to call once at launch.
    public func startEngine(deviceUID: String? = nil) throws {
        guard !isRunning else { return }

        // A fresh engine — AVAudioEngine cannot reliably restart after stop().
        let eng = AVAudioEngine()
        engine = eng

        // Set a specific input device directly on the engine's AudioUnit,
        // without touching the system-wide default input device.
        if let targetUID = deviceUID, !targetUID.isEmpty,
           let deviceID = findDeviceID(uid: targetUID),
           let audioUnit = eng.inputNode.audioUnit {
            var devID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = eng.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.processTap(buffer: buffer)
        }

        try eng.start()
        isRunning = true

        let name = deviceName(of: eng.inputNode)
        let cb = onDeviceName
        DispatchQueue.main.async { cb?(name) }
    }

    /// Tear the engine down completely (e.g. on quit or device switch).
    public func stopEngine() {
        guard isRunning else { return }
        lock.lock(); capturing = false; preroll.removeAll(keepingCapacity: false); lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }

    /// Begin forwarding audio for a PTT session, flushing the pre-roll first so
    /// the start of speech (and the instant before the press) isn't clipped.
    public func beginCapture() {
        lock.lock()
        let prerollSnapshot = preroll
        preroll.removeAll(keepingCapacity: true)
        // Emit the pre-roll, then enable live forwarding — all under the lock so
        // the next tap callback can't interleave a live chunk ahead of it.
        if !prerollSnapshot.isEmpty { onChunk?(prerollSnapshot) }
        capturing = true
        lock.unlock()
    }

    /// Stop forwarding audio; the engine stays warm.
    public func endCapture() {
        lock.lock()
        capturing = false
        lock.unlock()
    }

    /// Switch input device by restarting the warm engine.
    public func restartEngine(deviceUID: String?) {
        stopEngine()
        try? startEngine(deviceUID: deviceUID)
    }

    // MARK: - Private

    private func processTap(buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let inputFormat = buffer.format
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, outBuf.frameLength > 0,
              let int16Data = outBuf.int16ChannelData else { return }

        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)

        lock.lock()
        if capturing {
            let cb = onChunk
            lock.unlock()
            cb?(data)
        } else {
            // Keep only the most recent prerollMaxBytes of audio.
            preroll.append(data)
            if preroll.count > Self.prerollMaxBytes {
                preroll.removeFirst(preroll.count - Self.prerollMaxBytes)
            }
            lock.unlock()
        }
    }

    /// Find CoreAudio device ID by UID without side effects.
    private func findDeviceID(uid targetUID: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &devices)

        for id in devices {
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef)
            if let uid = uidRef as String?, uid == targetUID {
                return id
            }
        }
        return nil
    }

    /// Get the display name of the device actually used by the given input node.
    private func deviceName(of inputNode: AVAudioInputNode) -> String {
        guard let audioUnit = inputNode.audioUnit else { return "Unknown" }
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard deviceID != 0 else { return "Unknown" }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanagedName: Unmanaged<CFString>? = nil
        let status = withUnsafeMutablePointer(to: &unmanagedName) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(nameSize)) { rawPtr in
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, rawPtr)
            }
        }
        if status == noErr, let name = unmanagedName?.takeRetainedValue() {
            return name as String
        }
        return "Unknown"
    }
}
