import AVFoundation

public struct MediaError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Clips laid end to end in one AVMutableComposition (video and/or audio only: GoPro
/// timecode and telemetry tracks are left out).
public struct JoinedComposition {
    public let composition: AVMutableComposition
    public let videoTrack: AVMutableCompositionTrack?
    public let audioTrack: AVMutableCompositionTrack?
    /// Display size of the first clip (after its rotation transform).
    public let displaySize: CGSize
    public let preferredTransform: CGAffineTransform
    public let naturalSize: CGSize

    public var duration: CMTime { composition.duration }

    public static func build(_ urls: [URL], video: Bool = true, audio: Bool = true) throws -> JoinedComposition {
        guard !urls.isEmpty else { throw MediaError("No clips to process.") }
        let comp = AVMutableComposition()
        let vTrack = video ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var aTrack: AVMutableCompositionTrack? = nil
        var cursor = CMTime.zero
        var naturalSize = CGSize.zero
        var transform = CGAffineTransform.identity

        for (i, url) in urls.enumerated() {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let srcVideo = asset.tracks(withMediaType: .video).first
            let srcAudio = asset.tracks(withMediaType: .audio).first
            guard srcVideo != nil || srcAudio != nil else {
                throw MediaError("\(url.lastPathComponent) has no video or audio that macOS can read.")
            }
            // The clip's length on the timeline: its video track, else its audio track.
            let length = (srcVideo ?? srcAudio!).timeRange.duration

            if let vTrack = vTrack {
                guard let srcVideo = srcVideo else {
                    throw MediaError("\(url.lastPathComponent) has no video track.")
                }
                if i == 0 {
                    naturalSize = srcVideo.naturalSize
                    transform = srcVideo.preferredTransform
                }
                do {
                    try vTrack.insertTimeRange(srcVideo.timeRange, of: srcVideo, at: cursor)
                } catch {
                    throw MediaError("Couldn't read the video in \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if audio, let srcAudio = srcAudio {
                if aTrack == nil {
                    aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                // Keep audio aligned with the video: never longer than the clip.
                var range = srcAudio.timeRange
                if range.duration > length { range.duration = length }
                try? aTrack?.insertTimeRange(range, of: srcAudio, at: cursor)
            }
            cursor = cursor + length
        }
        vTrack?.preferredTransform = transform

        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let display = CGSize(width: abs(rect.width), height: abs(rect.height))
        return JoinedComposition(composition: comp, videoTrack: vTrack, audioTrack: aTrack,
                                 displaySize: display, preferredTransform: transform, naturalSize: naturalSize)
    }

    /// Cuts `start` seconds off the beginning and `end` seconds off the end.
    public func trim(start: Double, end: Double) throws {
        guard start > 0 || end > 0 else { return }
        let total = composition.duration.seconds
        guard start + end < total - 0.1 else {
            throw MediaError("Trimming \(Format.duration(start + end)) would leave nothing of the \(Format.duration(total)) video.")
        }
        let scale: CMTimeScale = 600
        if end > 0 {
            let cutStart = CMTime(seconds: total - end, preferredTimescale: scale)
            composition.removeTimeRange(CMTimeRange(start: cutStart, end: composition.duration))
        }
        if start > 0 {
            composition.removeTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: start, preferredTimescale: scale)))
        }
    }

    /// Plays the whole composition `speed` times faster.
    public func speedUp(_ speed: Double) {
        guard speed != 1 else { return }
        let full = CMTimeRange(start: .zero, duration: composition.duration)
        let newDuration = CMTimeMultiplyByFloat64(composition.duration, multiplier: 1.0 / speed)
        composition.scaleTimeRange(full, toDuration: newDuration)
    }

    /// Describes why the clips can't be joined losslessly, or nil if they can.
    public static func losslessIncompatibility(_ urls: [URL]) -> String? {
        var first: (codec: FourCharCode, size: CGSize, name: String)?
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first,
                  let desc = track.formatDescriptions.first else { continue }
            let fd = desc as! CMFormatDescription
            let codec = CMFormatDescriptionGetMediaSubType(fd)
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            let size = CGSize(width: Int(dims.width), height: Int(dims.height))
            if let f = first {
                if f.codec != codec {
                    return "\(url.lastPathComponent) uses a different video codec (\(fourCC(codec))) from \(f.name) (\(fourCC(f.codec)))."
                }
                if f.size != size {
                    return "\(url.lastPathComponent) is \(Int(size.width))×\(Int(size.height)) but \(f.name) is \(Int(f.size.width))×\(Int(f.size.height))."
                }
            } else {
                first = (codec, size, url.lastPathComponent)
            }
        }
        return nil
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }
}
