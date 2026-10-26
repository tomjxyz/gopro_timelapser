import AVFoundation
import CoreVideo

/// Writes small H.264 + AAC test clips with AVAssetWriter (no external tools needed).
enum TestClips {
    static func make(_ url: URL, seconds: Double, width: Int = 320, height: Int = 240, fps: Int32 = 30,
                     audio: Bool = true, tone: Double = 440) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        var format: CMAudioFormatDescription?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            aIn = input
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                   mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }

        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "TestClips", code: 1) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        let samplesPerFrame = 48_000 / Int(fps)
        for i in 0..<frames {
            // Video frame: a moving grey level so frames differ.
            waitReady(vIn)
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            if let pb = pb {
                CVPixelBufferLockBaseAddress(pb, [])
                let level = UInt8((i * 4) % 256)
                memset(CVPixelBufferGetBaseAddress(pb), Int32(level), CVPixelBufferGetDataSize(pb))
                CVPixelBufferUnlockBaseAddress(pb, [])
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
            }
            // Matching slice of a sine tone.
            if let aIn = aIn, let format = format {
                waitReady(aIn)
                let start = i * samplesPerFrame
                var samples = [Int16](repeating: 0, count: samplesPerFrame * 2)
                for n in 0..<samplesPerFrame {
                    let v = Int16(8000 * sin(2 * .pi * tone * Double(start + n) / 48_000))
                    samples[2 * n] = v
                    samples[2 * n + 1] = v
                }
                let bytes = samples.count * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                   blockBufferOut: &block)
                samples.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
                }
                var sb: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format,
                                                                     sampleCount: samplesPerFrame,
                                                                     presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000),
                                                                     packetDescriptions: nil, sampleBufferOut: &sb)
                if let sb = sb { aIn.append(sb) }
            }
        }
        vIn.markAsFinished()
        aIn?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "TestClips", code: 2) }
    }

    private static func waitReady(_ input: AVAssetWriterInput) {
        var tries = 0
        while !input.isReadyForMoreMediaData && tries < 5000 {
            usleep(1000)
            tries += 1
        }
    }
}
