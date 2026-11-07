import AVFoundation
import CoreAudio

/// A microphone or other audio input.
struct AudioInput: Identifiable, Hashable {
    /// AVCaptureDevice unique ID (Core Audio UID).
    let id: String
    let name: String
}

enum AudioInputs {
    static func all() -> [AudioInput] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { AudioInput(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The Core Audio device for a UID, to point an audio engine at it.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Asks once, then reports whether the microphone may be used.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    static let deniedMessage = "MyToolbox can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
}

/// Records a microphone to a file with AVAudioEngine. With `voiceProcessing` on, Apple's voice processing removes
/// steady background noise and the echo of whatever the Mac is playing, so mostly your voice is kept.
final class MicRecorder: @unchecked Sendable {
    struct Options: Equatable {
        var voiceProcessing = false
        var stereo = false
        /// nil = the input chosen in System Settings.
        var deviceUID: String?
    }

    let url: URL
    /// The file's sample rate.
    let sampleRate: Double
    /// 0…1, about 20 times a second, on the main queue.
    var onLevel: (@MainActor (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var writing = false
    private var frames: AVAudioFramePosition = 0
    private var lastLevel = Date.distantPast
    /// Only when the input runs faster than the file can store (AAC tops out at 48 kHz).
    private var converter: AVAudioConverter?

    /// `writeImmediately: false` keeps the engine warm but drops sound until `beginWriting()` (to line up with a video).
    init(url: URL, options: Options, writeImmediately: Bool = true) throws {
        self.url = url
        let input = engine.inputNode
        if let uid = options.deviceUID, var device = AudioInputs.deviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if options.voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Don't turn down other apps while recording (that would also quieten recorded system audio).
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw ToolError("No microphone input was found. Check System Settings → Sound → Input.") }
        let channels: AVAudioChannelCount = options.stereo ? 2 : 1
        let file = try AVAudioFile(forWriting: url, settings: Self.settings(for: url.pathExtension, sampleRate: inFormat.sampleRate, channels: channels),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        sampleRate = file.processingFormat.sampleRate
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: channels, interleaved: false) else {
            throw ToolError("Can't record in this format.")
        }
        if outFormat.sampleRate != file.processingFormat.sampleRate {
            converter = AVAudioConverter(from: outFormat, to: file.processingFormat)
        }
        // Voice processing hands over the cleaned voice on the first channel (the others can be reference channels).
        let voiceOnly = options.voiceProcessing
        writing = writeImmediately
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, outFormat: outFormat, voiceOnly: voiceOnly)
        }
    }

    static func settings(for ext: String, sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        switch ext.lowercased() {
        case "m4a":
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: min(sampleRate, 48_000), AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 2 ? 192_000 : 128_000]
        case "wav":
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        default:   // caf, for intermediate files
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func beginWriting() { lock.lock(); writing = true; lock.unlock() }
    func setPaused(_ paused: Bool) { lock.lock(); writing = !paused; lock.unlock() }

    /// Seconds written so far.
    var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(frames) / sampleRate }

    /// Stops and finishes the file; returns its length in seconds.
    @discardableResult func stop() -> Double {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        file = nil   // closing the file writes its header
        writing = false
        let d = Double(frames) / sampleRate
        lock.unlock()
        return d
    }

    private func handle(_ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat, voiceOnly: Bool) {
        if let level = Self.level(buffer), Date().timeIntervalSince(lastLevel) > 0.05 {
            lastLevel = Date()
            if let onLevel { DispatchQueue.main.async { MainActor.assumeIsolated { onLevel(level) } } }
        }
        lock.lock(); defer { lock.unlock() }
        guard writing, let file, let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: buffer.frameLength) else { return }
        Self.copyChannels(from: buffer, to: out, voiceOnly: voiceOnly)
        var toWrite = out
        if let converter {
            let capacity = AVAudioFrameCount(Double(out.frameLength) * file.processingFormat.sampleRate / out.format.sampleRate) + 32
            guard let resampled = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
            var given = false
            _ = converter.convert(to: resampled, error: nil) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return out
            }
            toWrite = resampled
        }
        if (try? file.write(from: toWrite)) != nil { frames += AVAudioFramePosition(toWrite.frameLength) }
    }

    /// Copies sound into a mono or stereo float buffer: the first input channel (and the second, for stereo from a
    /// stereo input; with `voiceOnly` the voice channel goes to both sides).
    static func copyChannels(from input: AVAudioPCMBuffer, to output: AVAudioPCMBuffer, voiceOnly: Bool) {
        let n = Int(input.frameLength)
        output.frameLength = input.frameLength
        guard let src = input.floatChannelData, let dst = output.floatChannelData else { return }
        let inChannels = Int(input.format.channelCount)
        for ch in 0..<Int(output.format.channelCount) {
            let from = voiceOnly ? 0 : min(ch, inChannels - 1)
            dst[ch].update(from: src[from], count: n)
        }
    }

    /// RMS of the first channel, −50…0 dB mapped to 0…1.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }
}
