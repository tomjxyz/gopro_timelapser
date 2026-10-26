import AVFoundation

public enum VideoCodec: Int {
    case h264, hevc
}

public enum AudioMode: Int {
    /// No sound in the output.
    case none
    /// Sped up with pitch kept natural (time-stretch).
    case keepPitch
    /// Sped up like fast-forwarding a tape: pitch rises with speed.
    case chipmunk
}

public struct EncodeSettings {
    /// 1 = normal speed (join), 2...400 for a timelapse.
    public var speed: Double = 1
    /// Output height in pixels, or nil for the source resolution. Never upscales.
    public var maxHeight: Int? = 1080
    /// 0 = smallest file ... 1 = best quality.
    public var quality: Double = 0.5
    public var fps: Int = 30
    public var codec: VideoCodec = .h264
    public var audio: AudioMode = .none
    public var trimStart: Double = 0
    public var trimEnd: Double = 0
    /// Written into the output's metadata and file dates when set.
    public var recordingDate: Date?

    public init() {}

    /// Bits per pixel per frame for the quality slider, on a log scale from 0.03 to 0.30.
    public var bitsPerPixel: Double { 0.03 * pow(10, quality) }

    public func bitrate(width: Int, height: Int) -> Int {
        let base = bitsPerPixel * Double(width * height * fps)
        let codecFactor = codec == .hevc ? 0.6 : 1.0
        return max(250_000, Int(base * codecFactor))
    }

    /// Output size for a source of the given display size: limited to maxHeight, even dimensions.
    public func outputSize(for display: CGSize) -> CGSize {
        let srcH = max(2, display.height)
        let h = min(CGFloat(maxHeight ?? Int(srcH)), srcH)
        let w = display.width * h / srcH
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(w), height: even(h))
    }
}

/// Re-encodes clips (joined in order) with optional speed-up, scaling and sound processing.
/// AVAssetReader → AVAssetWriter, so decoding, scaling and encoding use the Mac's hardware.
public final class Transcoder {
    public var onProgress: ((Double, String) -> Void)?
    public var onLog: ((String) -> Void)?

    private let urls: [URL]
    private let output: URL
    private let settings: EncodeSettings
    private let lock = NSLock()
    private var cancelled = false
    private var activeReaders: [AVAssetReader] = []
    private var activeWriter: AVAssetWriter?
    private var tempFiles: [URL] = []

    public init(urls: [URL], output: URL, settings: EncodeSettings) {
        self.urls = urls
        self.output = output
        self.settings = settings
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let readers = activeReaders
        let writer = activeWriter
        lock.unlock()
        readers.forEach { $0.cancelReading() }
        writer?.cancelWriting()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Runs synchronously; call from a background queue.
    public func run() throws {
        defer { tempFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            try runInner()
        } catch {
            try? FileManager.default.removeItem(at: output)
            if isCancelled { throw JobCancelled() }
            throw error
        }
        if isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw JobCancelled()
        }
        if let date = settings.recordingDate { OutputMetadata.setFileDates(output, date) }
    }

    private func runInner() throws {
        try? FileManager.default.removeItem(at: output)
        let s = settings

        // ---- video timeline
        let video = try JoinedComposition.build(urls, video: true, audio: false)
        try video.trim(start: s.trimStart, end: s.trimEnd)
        video.speedUp(s.speed)
        let outDuration = video.duration
        guard let vTrack = video.videoTrack, outDuration.seconds > 0 else { throw MediaError("The clips contain no video.") }

        let size = s.outputSize(for: video.displaySize)
        let bitrate = s.bitrate(width: Int(size.width), height: Int(size.height))
        log("Output \(Int(size.width))×\(Int(size.height)) @ \(s.fps) fps, \(s.codec == .hevc ? "HEVC" : "H.264") ~\(bitrate / 1000) kbit/s, length \(Format.duration(outDuration.seconds))")

        // ---- sound
        var audioSource: (asset: AVAsset, algorithm: AVAudioTimePitchAlgorithm?)? = nil
        if s.audio != .none {
            audioSource = try prepareAudio()
            if audioSource == nil { log("The clips have no sound; the output will be silent.") }
        }
        if isCancelled { throw JobCancelled() }

        // ---- writer
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        if let date = s.recordingDate { writer.metadata = OutputMetadata.items(for: date) }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: s.fps,
            AVVideoMaxKeyFrameIntervalKey: s.fps * 2,
        ]
        if s.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: s.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw MediaError("This Mac can't encode \(s.codec == .hevc ? "HEVC" : "H.264") at \(Int(size.width))×\(Int(size.height)).") }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput? = nil
        if audioSource != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        // ---- readers
        let videoReader = try AVAssetReader(asset: video.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.videoComposition = makeVideoComposition(video, renderSize: size)
        videoOut.alwaysCopiesSampleData = false
        videoReader.add(videoOut)

        var audioReader: AVAssetReader? = nil
        var audioOut: AVAssetReaderAudioMixOutput? = nil
        if let src = audioSource, audioIn != nil {
            let reader = try AVAssetReader(asset: src.asset)
            let out = AVAssetReaderAudioMixOutput(audioTracks: src.asset.tracks(withMediaType: .audio), audioSettings: Self.pcmSettings)
            if let alg = src.algorithm { out.audioTimePitchAlgorithm = alg }
            reader.add(out)
            audioReader = reader
            audioOut = out
        }

        lock.lock()
        activeWriter = writer
        activeReaders = [videoReader] + (audioReader.map { [$0] } ?? [])
        lock.unlock()

        guard writer.startWriting() else { throw MediaError("Couldn't start writing: \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
        guard videoReader.startReading() else { throw MediaError("Couldn't read the clips: \(videoReader.error?.localizedDescription ?? "unknown error")") }
        if let r = audioReader, !r.startReading() { throw MediaError("Couldn't read the sound: \(r.error?.localizedDescription ?? "unknown error")") }

        let group = DispatchGroup()
        let total = outDuration.seconds
        let start = Date()
        pump(videoOut, into: videoIn, label: "video", group: group) { [weak self] pts in
            let p = min(1, max(0, pts.seconds / total))
            self?.onProgress?(p, Self.statusText(p, since: start))
        }
        if let audioOut = audioOut, let audioIn = audioIn {
            pump(audioOut, into: audioIn, label: "audio", group: group, progress: nil)
        }
        waitForPumps(group, writer: writer, readers: [videoReader] + (audioReader.map { [$0] } ?? []))

        if isCancelled { writer.cancelWriting(); throw JobCancelled() }
        if writer.status == .failed {
            throw MediaError("Writing the video failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        if videoReader.status == .failed {
            writer.cancelWriting()
            throw MediaError("Reading the clips failed: \(videoReader.error?.localizedDescription ?? "unknown error")")
        }
        if let r = audioReader, r.status == .failed {
            writer.cancelWriting()
            throw MediaError("Reading the sound failed: \(r.error?.localizedDescription ?? "unknown error")")
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw MediaError("Writing the video failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        onProgress?(1, "Finished in \(Format.duration(Date().timeIntervalSince(start)))")
    }

    /// Builds the sped-up sound source. Apple's time-stretch handles up to 32× per pass, so higher
    /// speeds go through a temporary file at √speed and are then sped up by √speed again.
    private func prepareAudio() throws -> (asset: AVAsset, algorithm: AVAudioTimePitchAlgorithm?)? {
        let s = settings
        let audio = try JoinedComposition.build(urls, video: false, audio: true)
        guard audio.audioTrack != nil else { return nil }
        try audio.trim(start: s.trimStart, end: s.trimEnd)
        if s.speed == 1 { return (audio.composition, nil) }

        let algorithm: AVAudioTimePitchAlgorithm = s.audio == .chipmunk ? .varispeed : .spectral
        let maxPerPass = 32.0
        if s.speed <= maxPerPass {
            audio.speedUp(s.speed)
            return (audio.composition, algorithm)
        }

        let step = s.speed.squareRoot()
        audio.speedUp(step)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-audio-\(UUID().uuidString).caf")
        tempFiles.append(temp)
        log("Preparing sound (\(Int(s.speed))× in two passes of \(String(format: "%.1f", step))×)…")
        onProgress?(0, "Preparing sound…")
        try renderAudio(audio.composition, algorithm: algorithm, to: temp)

        let second = try JoinedComposition.build([temp], video: false, audio: true)
        second.speedUp(step)
        return (second.composition, algorithm)
    }

    /// Writes an asset's (scaled) sound to an uncompressed CAF file.
    private func renderAudio(_ asset: AVAsset, algorithm: AVAudioTimePitchAlgorithm, to url: URL) throws {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: asset.tracks(withMediaType: .audio), audioSettings: Self.pcmSettings)
        out.audioTimePitchAlgorithm = algorithm
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.pcmSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        lock.lock(); activeReaders = [reader]; activeWriter = writer; lock.unlock()
        guard writer.startWriting(), reader.startReading() else {
            throw MediaError("Couldn't process the sound: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        pump(out, into: input, label: "audio-prepass", group: group, progress: nil)
        waitForPumps(group, writer: writer, readers: [reader])
        if isCancelled { throw JobCancelled() }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if reader.status == .failed || writer.status != .completed {
            throw MediaError("Processing the sound failed: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
    }

    private func makeVideoComposition(_ video: JoinedComposition, renderSize: CGSize) -> AVVideoComposition {
        let scale = renderSize.height / max(1, video.displaySize.height)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video.videoTrack!)
        layer.setTransform(video.preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: video.duration)
        instruction.layerInstructions = [layer]
        let vc = AVMutableVideoComposition()
        vc.instructions = [instruction]
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        vc.renderSize = renderSize
        return vc
    }

    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                      group: DispatchGroup, progress: ((CMTime) -> Void)?) {
        group.enter()
        let queue = DispatchQueue(label: "gpt.pump.\(label)")
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard !finished else { return }
            func finish() {
                finished = true
                input.markAsFinished()
                group.leave()
            }
            while input.isReadyForMoreMediaData {
                if self?.isCancelled ?? true { finish(); return }
                guard let buffer = output.copyNextSampleBuffer() else { finish(); return }
                if !input.append(buffer) { finish(); return }
                progress?(CMSampleBufferGetPresentationTimeStamp(buffer))
            }
        }
    }

    /// Waits for the pumps to finish. If the writer fails or is cancelled it stops asking for data,
    /// so the pumps would never finish on their own: stop the readers and return instead.
    private func waitForPumps(_ group: DispatchGroup, writer: AVAssetWriter, readers: [AVAssetReader]) {
        while group.wait(timeout: .now() + 0.5) == .timedOut {
            if writer.status == .failed || writer.status == .cancelled || isCancelled {
                readers.forEach { $0.cancelReading() }
                return
            }
        }
    }

    private func log(_ line: String) { onLog?(line) }

    static func statusText(_ p: Double, since start: Date) -> String {
        let elapsed = Date().timeIntervalSince(start)
        var text = String(format: "Encoding… %.0f%%   elapsed %@", p * 100, Format.duration(elapsed))
        if p > 0.02 { text += "   remaining ≈ " + Format.duration(elapsed * (1 - p) / p) }
        return text
    }

    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 160_000,
    ]
}

public struct JobCancelled: LocalizedError {
    public init() {}
    public var errorDescription: String? { "Cancelled." }
}
