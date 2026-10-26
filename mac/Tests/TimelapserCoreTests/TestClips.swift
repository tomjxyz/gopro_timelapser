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

        // Each input pulls its own data on its own queue (the pattern that never stalls the writer).
        let frames = Int(seconds * Double(fps))
        let group = DispatchGroup()

        group.enter()
        var frame = 0
        vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "testclips.video")) {
            while vIn.isReadyForMoreMediaData {
                if frame >= frames { vIn.markAsFinished(); group.leave(); return }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
                if let pb = pb {
                    // A moving grey level so frames differ.
                    CVPixelBufferLockBaseAddress(pb, [])
                    memset(CVPixelBufferGetBaseAddress(pb), Int32((frame * 4) % 256), CVPixelBufferGetDataSize(pb))
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                }
                frame += 1
            }
        }

        if let aIn = aIn, let format = format {
            group.enter()
            let chunk = 4800
            let totalSamples = Int(seconds * 48_000)
            var start = 0
            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "testclips.audio")) {
                while aIn.isReadyForMoreMediaData {
                    if start >= totalSamples { aIn.markAsFinished(); group.leave(); return }
                    let count = min(chunk, totalSamples - start)
                    var samples = [Int16](repeating: 0, count: count * 2)
                    for n in 0..<count {
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
                                                                         sampleCount: count,
                                                                         presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000),
                                                                         packetDescriptions: nil, sampleBufferOut: &sb)
                    if let sb = sb { aIn.append(sb) }
                    start += count
                }
            }
        }

        // A failed writer stops asking for data, so don't wait on the group forever.
        while group.wait(timeout: .now() + 0.5) == .timedOut {
            if writer.status == .failed { throw writer.error ?? NSError(domain: "TestClips", code: 3) }
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "TestClips", code: 2) }
    }
}
