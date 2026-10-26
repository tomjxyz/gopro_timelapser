import AVFoundation

/// Speeds up interleaved 16-bit stereo audio by any factor (2–400×), streaming.
///
/// * Chipmunk: every `speed` input samples are averaged into one output sample, which plays the sound
///   `speed` times faster with the pitch rising accordingly (the averaging doubles as a low-pass filter).
/// * Keep pitch: overlap-add of short Hann-windowed snippets (~43 ms) taken from evenly spaced points in
///   the input, so the sound keeps its natural pitch. At high speeds this is a rapid montage of snippets.
public final class AudioSpeedProcessor {
    public static let channels = 2
    public let speed: Double
    public let keepPitch: Bool

    // Chipmunk state
    private var inputIndex = 0
    private var currentOut = 0
    private var sum = [Double](repeating: 0, count: channels)
    private var count = 0

    // Keep-pitch (overlap-add) state
    private let grain = 2048
    private let hop = 1024
    private lazy var window: [Float] = (0..<grain).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(grain)) }
    private var input: [Float] = []          // interleaved, first frame is absolute frame `inputStart`
    private var inputStart = 0
    private var inputFrames = 0
    private var grainIndex = 0
    private var acc: [Float] = []            // interleaved overlap-add accumulator, first frame is `accStart`
    private var accStart = 0

    public init(speed: Double, keepPitch: Bool) {
        self.speed = max(1, speed)
        self.keepPitch = keepPitch
    }

    /// Feeds interleaved stereo samples; returns finished output samples (interleaved).
    public func process(_ samples: [Int16]) -> [Int16] {
        keepPitch ? overlapAdd(samples) : decimate(samples)
    }

    /// Flushes what is left at the end of the input.
    public func finish() -> [Int16] {
        if keepPitch {
            let out = acc
            acc = []
            return out.map(Self.toInt16)
        }
        guard count > 0 else { return [] }
        let out = sum.map { Self.toInt16(Float($0 / Double(count))) }
        count = 0
        return out
    }

    private func decimate(_ samples: [Int16]) -> [Int16] {
        let ch = Self.channels
        var out: [Int16] = []
        out.reserveCapacity(Int(Double(samples.count) / speed) + ch)
        var i = 0
        while i + ch <= samples.count {
            let target = Int(Double(inputIndex) / speed)
            if target != currentOut && count > 0 {
                for c in 0..<ch { out.append(Self.toInt16(Float(sum[c] / Double(count)))) }
                sum = [Double](repeating: 0, count: ch)
                count = 0
            }
            currentOut = target
            for c in 0..<ch { sum[c] += Double(samples[i + c]) }
            count += 1
            inputIndex += 1
            i += ch
        }
        return out
    }

    private func overlapAdd(_ samples: [Int16]) -> [Int16] {
        let ch = Self.channels
        input.append(contentsOf: samples.map { Float($0) })
        inputFrames += samples.count / ch

        var out: [Int16] = []
        while true {
            let readPos = Int(Double(grainIndex * hop) * speed)   // absolute input frame for this grain
            guard readPos + grain <= inputFrames else { break }
            let writePos = grainIndex * hop                      // absolute output frame
            let needed = (writePos - accStart + grain) * ch
            if acc.count < needed { acc.append(contentsOf: [Float](repeating: 0, count: needed - acc.count)) }
            let inOff = (readPos - inputStart) * ch
            let accOff = (writePos - accStart) * ch
            for t in 0..<grain {
                let w = window[t]
                for c in 0..<ch {
                    acc[accOff + t * ch + c] += input[inOff + t * ch + c] * w
                }
            }
            grainIndex += 1

            // Output before the next grain's start is final.
            let finalFrames = grainIndex * hop - accStart
            out.append(contentsOf: acc[0..<(finalFrames * ch)].map(Self.toInt16))
            acc.removeFirst(finalFrames * ch)
            accStart += finalFrames

            // Input before the next grain's read position is no longer needed.
            let nextRead = Int(Double(grainIndex * hop) * speed)
            let drop = min(max(0, nextRead - inputStart), inputFrames - inputStart)
            if drop > 0 {
                input.removeFirst(drop * ch)
                inputStart += drop
            }
        }
        return out
    }

    private static func toInt16(_ v: Float) -> Int16 {
        Int16(max(-32768, min(32767, v.rounded())))
    }
}

/// Converts between CMSampleBuffers and interleaved 16-bit stereo PCM at 48 kHz.
enum PCM {
    static let sampleRate = 48_000

    static let readerSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: AudioSpeedProcessor.channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    static func samples(from buffer: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var out = [Int16](repeating: 0, count: length / 2)
        out.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return out
    }

    static let format: CMAudioFormatDescription = {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        return fmt!
    }()

    /// Wraps interleaved stereo samples starting at absolute frame `startFrame`.
    static func sampleBuffer(_ samples: [Int16], startFrame: Int) -> CMSampleBuffer? {
        let frames = samples.count / 2
        guard frames > 0 else { return nil }
        let bytes = frames * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        guard let block = block else { return nil }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}

/// Pulls PCM from a reader output, speeds it up, and hands out ready-to-encode sample buffers.
final class SpedUpAudioSource {
    private let output: AVAssetReaderOutput
    private let processor: AudioSpeedProcessor
    private var pending: [Int16] = []
    private var emittedFrames = 0
    private var inputDone = false
    private let chunkFrames = 4800

    init(output: AVAssetReaderOutput, processor: AudioSpeedProcessor) {
        self.output = output
        self.processor = processor
    }

    func next() -> CMSampleBuffer? {
        while true {
            if pending.count >= chunkFrames * 2 || (inputDone && !pending.isEmpty) {
                let n = min(pending.count, chunkFrames * 2)
                let chunk = Array(pending[0..<n])
                pending.removeFirst(n)
                let sb = PCM.sampleBuffer(chunk, startFrame: emittedFrames)
                emittedFrames += n / 2
                return sb
            }
            if inputDone { return nil }
            if let buffer = output.copyNextSampleBuffer() {
                pending += processor.process(PCM.samples(from: buffer))
            } else {
                pending += processor.finish()
                inputDone = true
            }
        }
    }
}
