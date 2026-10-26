import AVFoundation

/// Joins clips without re-encoding (stream copy), so it is fast and loses no quality.
public final class LosslessJoiner {
    public var onProgress: ((Double, String) -> Void)?
    public var onLog: ((String) -> Void)?

    private let urls: [URL]
    private let output: URL
    private let includeAudio: Bool
    private let trimStart: Double
    private let trimEnd: Double
    private let recordingDate: Date?
    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var cancelled = false

    public init(urls: [URL], output: URL, includeAudio: Bool, trimStart: Double, trimEnd: Double, recordingDate: Date?) {
        self.urls = urls
        self.output = output
        self.includeAudio = includeAudio
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.recordingDate = recordingDate
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let s = session
        lock.unlock()
        s?.cancelExport()
    }

    /// Runs synchronously; call from a background queue.
    public func run() throws {
        if let problem = JoinedComposition.losslessIncompatibility(urls) {
            throw MediaError("These clips can't be joined losslessly: \(problem)\n\nChoose \"Re-encode\" to join them anyway.")
        }
        let joined = try JoinedComposition.build(urls, video: true, audio: includeAudio)
        try joined.trim(start: trimStart, end: trimEnd)
        onLog?("Joining \(urls.count) clips losslessly, length \(Format.duration(joined.duration.seconds))")

        guard let export = AVAssetExportSession(asset: joined.composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MediaError("macOS couldn't set up a lossless export for these clips.")
        }
        let fileType: AVFileType = export.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        if fileType != .mp4 { onLog?("MP4 isn't supported for these clips; writing QuickTime (.mov) data instead.") }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = true
        if let date = recordingDate { export.metadata = OutputMetadata.items(for: date) }

        lock.lock()
        if cancelled { lock.unlock(); throw JobCancelled() }
        session = export
        lock.unlock()

        let start = Date()
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            let p = Double(export.progress)
            onProgress?(p, Transcoder.statusText(p, since: start).replacingOccurrences(of: "Encoding", with: "Joining"))
        }

        switch export.status {
        case .completed:
            if let date = recordingDate { OutputMetadata.setFileDates(output, date) }
            onProgress?(1, "Finished in \(Format.duration(Date().timeIntervalSince(start)))")
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            throw JobCancelled()
        default:
            try? FileManager.default.removeItem(at: output)
            throw MediaError("Joining failed: \(export.error?.localizedDescription ?? "unknown error")")
        }
    }
}
