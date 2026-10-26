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

    public init(urls: [URL], output: URL, settings: EncodeSettings) {
        self.urls = urls
        self.output = output
        self.settings = settings
    }

    /// Asks the job to stop. The encode loops notice between frames; the writer is then
    /// cancelled from the job's own thread, never while a frame is being appended.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Runs synchronously; call from a background queue.
    public func run() throws {
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

        // ---- sound: read unscaled, speed up in AudioSpeedProcessor (any factor, one pass)
        var audioReader: AVAssetReader? = nil
        var audioOut: AVAssetReaderAudioMixOutput? = nil
        if s.audio != .none {
            let audio = try JoinedComposition.build(urls, video: false, audio: true)
            if audio.audioTrack != nil {
                try audio.trim(start: s.trimStart, end: s.trimEnd)
                let reader = try AVAssetReader(asset: audio.composition)
                let out = AVAssetReaderAudioMixOutput(audioTracks: audio.composition.tracks(withMediaType: .audio),
                                                      audioSettings: PCM.readerSettings)
                reader.add(out)
                audioReader = reader
                audioOut = out
            } else {
                log("The clips have no sound; the output will be silent.")
            }
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
        if audioReader != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input } else { audioReader = nil; audioOut = nil }
        }

        // ---- video reader: the composition renders only the frames needed at the output frame rate
        let videoReader = try AVAssetReader(asset: video.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [vTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.videoComposition = makeVideoComposition(video, renderSize: size)
        videoOut.alwaysCopiesSampleData = false
        videoReader.add(videoOut)

        let readers = [videoReader] + (audioReader.map { [$0] } ?? [])
        guard writer.startWriting() else { throw MediaError("Couldn't start writing: \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
        guard videoReader.startReading() else { throw MediaError("Couldn't read the clips: \(videoReader.error?.localizedDescription ?? "unknown error")") }
        if let r = audioReader, !r.startReading() { throw MediaError("Couldn't read the sound: \(r.error?.localizedDescription ?? "unknown error")") }

        let group = DispatchGroup()
        let total = outDuration.seconds
        let start = Date()
        pump(into: videoIn, writer: writer, label: "video", group: group, next: { videoOut.copyNextSampleBuffer() }) { [weak self] pts in
            let p = min(1, max(0, pts.seconds / total))
            self?.onProgress?(p, Self.statusText(p, since: start))
        }
        if let audioOut = audioOut, let audioIn = audioIn {
            if s.speed == 1 {
                pump(into: audioIn, writer: writer, label: "audio", group: group, next: { audioOut.copyNextSampleBuffer() }, progress: nil)
            } else {
                let source = SpedUpAudioSource(output: audioOut,
                                               processor: AudioSpeedProcessor(speed: s.speed, keepPitch: s.audio == .keepPitch))
                pump(into: audioIn, writer: writer, label: "audio", group: group, next: { source.next() }, progress: nil)
            }
        }
        waitForPumps(group, writer: writer, readers: readers)

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

    private func pump(into input: AVAssetWriterInput, writer: AVAssetWriter, label: String, group: DispatchGroup,
                      next: @escaping () -> CMSampleBuffer?, progress: ((CMTime) -> Void)?) {
        group.enter()
        let queue = DispatchQueue(label: "gpt.pump.\(label)")
        var finished = false
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard !finished else { return }
            func finish() {
                finished = true
                // Only a writer that is still writing accepts markAsFinished.
                if writer.status == .writing { input.markAsFinished() }
                group.leave()
            }
            while input.isReadyForMoreMediaData {
                if self?.isCancelled ?? true || writer.status != .writing { finish(); return }
                guard let buffer = next() else { finish(); return }
                if !input.append(buffer) { finish(); return }
                progress?(CMSampleBufferGetPresentationTimeStamp(buffer))
            }
        }
    }

    /// Waits for the pumps to finish. A failed writer stops asking for data, so its pumps would
    /// never finish on their own; after cancelling, the pumps get a moment to wind down.
    private func waitForPumps(_ group: DispatchGroup, writer: AVAssetWriter, readers: [AVAssetReader]) {
        var stopSince: Date?
        while group.wait(timeout: .now() + 0.25) == .timedOut {
            if writer.status == .failed || isCancelled {
                if stopSince == nil { stopSince = Date() }
                if Date().timeIntervalSince(stopSince!) > 3 { return }
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
