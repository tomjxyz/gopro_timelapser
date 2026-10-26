import AVFoundation
import XCTest
@testable import TimelapserCore

/// Prints straight to stderr (unbuffered) so CI shows progress even if a test hangs.
func trace(_ text: String) {
    FileHandle.standardError.write("[\(Date())] \(text)\n".data(using: .utf8)!)
}

final class TimelapserCoreTests: XCTestCase {
    static var dir: URL!
    static var clips: [URL] = []   // 3 × 20 s, 320×240, with a tone

    override class func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gpt-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clips = ["GX010042.MP4", "GX020042.MP4", "GX030042.MP4"].enumerated().map { i, name in
            let url = dir.appendingPathComponent(name)
            trace("making test clip \(name)")
            try! TestClips.make(url, seconds: 20, tone: 300 + Double(i) * 200)
            trace("made test clip \(name)")
            return url
        }
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func out(_ name: String) -> URL { Self.dir.appendingPathComponent(name) }

    override func setUp() {
        super.setUp()
        trace("start \(name)")
    }

    override func tearDown() {
        trace("end \(name)")
        super.tearDown()
    }

    /// Runs a job with a time limit; on timeout it is cancelled and the test fails with its log.
    private func runJob(_ job: MediaJob, timeout: TimeInterval = 60) throws {
        var lines: [String] = []
        let lock = NSLock()
        job.onLog = { line in lock.lock(); lines.append(line); lock.unlock(); trace("  log: \(line)") }
        var lastStatus = ""
        job.onProgress = { _, status in lock.lock(); lastStatus = status; lock.unlock() }
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try job.run() } catch { failure = error }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            job.cancel()
            let cancelled = done.wait(timeout: .now() + 10) == .success
            lock.lock(); defer { lock.unlock() }
            throw MediaError("Timed out after \(Int(timeout)) s (cancel \(cancelled ? "worked" : "also hung")). Last status: \(lastStatus). Log: \(lines.joined(separator: " | "))")
        }
        if let failure = failure { throw failure }
    }

    private func videoInfo(_ url: URL) -> (duration: Double, size: CGSize, fps: Float, hasAudio: Bool, audioDuration: Double) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = asset.tracks(withMediaType: .video).first
        let a = asset.tracks(withMediaType: .audio).first
        return (asset.duration.seconds, v?.naturalSize ?? .zero, v?.nominalFrameRate ?? 0, a != nil, a?.timeRange.duration.seconds ?? 0)
    }

    // MARK: - Pure logic

    func testGoProOrderKeyPutsChaptersInOrder() {
        let names = ["GX020042.MP4", "GX010043.MP4", "GX010042.MP4", "GOPR0041.MP4"]
        let sorted = names.sorted { Clip.goProOrderKey($0) < Clip.goProOrderKey($1) }
        XCTAssertEqual(sorted, ["GOPR0041.MP4", "GX010042.MP4", "GX020042.MP4", "GX010043.MP4"])
    }

    func testParseDuration() {
        XCTAssertEqual(Format.parseDuration("15"), 15)
        XCTAssertEqual(Format.parseDuration("1:30"), 90)
        XCTAssertEqual(Format.parseDuration("1:02:03"), 3723)
        XCTAssertEqual(Format.parseDuration(""), 0)
        XCTAssertNil(Format.parseDuration("abc"))
        XCTAssertEqual(Format.duration(3723), "1:02:03")
        XCTAssertEqual(Format.duration(90), "1:30")
    }

    func testMvhdParsingReadsCameraWallClock() throws {
        // Hand-built 'moov' box with an 'mvhd' (version 0): 2026-10-01 12:34:56 wall clock, 90 s at timescale 1000.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let epoch = utc.date(from: DateComponents(year: 1904, month: 1, day: 1))!
        let wall = utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12, minute: 34, second: 56))!
        let secs = UInt32(wall.timeIntervalSince(epoch))
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        var mvhdBody: [UInt8] = [0, 0, 0, 0] + be32(secs) + be32(secs) + be32(1000) + be32(90_000)
        mvhdBody += [UInt8](repeating: 0, count: 80)
        let mvhd = be32(UInt32(8 + mvhdBody.count)) + Array("mvhd".utf8) + mvhdBody
        let moov = be32(UInt32(8 + mvhd.count)) + Array("moov".utf8) + mvhd
        let ftyp = be32(16) + Array("ftypisom".utf8) + be32(0)
        let url = out("synthetic.mp4")
        try Data(ftyp + moov).write(to: url)

        let info = MP4Header.read(url)
        XCTAssertEqual(info.duration ?? 0, 90, accuracy: 0.001)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let c = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(info.creationWallClock))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 1, 12, 34, 56])
    }

    func testClipLoadReadsDuration() {
        let clip = Clip.load(Self.clips[0])
        XCTAssertEqual(clip.duration ?? 0, 20, accuracy: 0.1)
        XCTAssertNotNil(clip.recorded)
    }

    // MARK: - Sound speed-up

    /// 10 s of a stereo sine tone at 48 kHz, interleaved.
    private func tone(_ hz: Double, seconds: Double = 10) -> [Int16] {
        let n = Int(seconds * 48_000)
        var out = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = Int16(10_000 * sin(2 * .pi * hz * Double(i) / 48_000))
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }

    /// Estimated frequency of the left channel from zero crossings.
    private func frequency(_ samples: [Int16]) -> Double {
        let left = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
        var crossings = 0
        for i in 1..<left.count where (left[i - 1] < 0) != (left[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(left.count) / 48_000)
    }

    private func speedUp(_ input: [Int16], speed: Double, keepPitch: Bool) -> [Int16] {
        let p = AudioSpeedProcessor(speed: speed, keepPitch: keepPitch)
        var out: [Int16] = []
        // Feed in uneven chunks like a real reader would.
        var i = 0
        let chunks = [2048, 9600, 1024, 4800]
        var k = 0
        while i < input.count {
            let n = min(chunks[k % chunks.count] * 2, input.count - i)
            out += p.process(Array(input[i..<(i + n)]))
            i += n
            k += 1
        }
        return out + p.finish()
    }

    func testAudioSpeedLengths() {
        let input = tone(440)
        for speed in [2.0, 10, 37, 100, 400] {
            for keep in [true, false] {
                let out = speedUp(input, speed: speed, keepPitch: keep)
                let expected = Double(input.count) / speed
                XCTAssertEqual(Double(out.count), expected, accuracy: max(expected * 0.05, 4096 * 2 + 2),
                               "speed \(speed) keepPitch \(keep)")
            }
        }
    }

    func testKeepPitchKeepsPitchAndChipmunkRaisesIt() {
        let input = tone(220, seconds: 20)
        let kept = speedUp(input, speed: 4, keepPitch: true)
        XCTAssertEqual(frequency(kept), 220, accuracy: 15)
        let chip = speedUp(input, speed: 4, keepPitch: false)
        XCTAssertEqual(frequency(chip), 880, accuracy: 40)
    }

    func testCancelStopsCleanly() throws {
        var s = EncodeSettings()
        s.speed = 2
        s.maxHeight = nil
        s.audio = .keepPitch
        let url = out("cancelled.mp4")
        let job = Transcoder(urls: Self.clips, output: url, settings: s)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { job.cancel() }
        XCTAssertThrowsError(try runJob(job, timeout: 30)) { error in
            XCTAssertTrue(error is JobCancelled, "got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Timelapse

    private func timelapse(speed: Double, audio: AudioMode, name: String) throws -> URL {
        var s = EncodeSettings()
        s.speed = speed
        s.maxHeight = 120
        s.fps = 30
        s.audio = audio
        let url = out(name)
        try runJob(Transcoder(urls: Self.clips, output: url, settings: s))
        return url
    }

    func testTimelapse10xWithSoundKeepPitch() throws {
        let info = videoInfo(try timelapse(speed: 10, audio: .keepPitch, name: "tl10.mp4"))
        XCTAssertEqual(info.duration, 6, accuracy: 0.3)
        XCTAssertEqual(info.size, CGSize(width: 160, height: 120))
        XCTAssertEqual(Double(info.fps), 30, accuracy: 1.5)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.audioDuration, 6, accuracy: 0.4)
    }

    func testTimelapse10xChipmunk() throws {
        let info = videoInfo(try timelapse(speed: 10, audio: .chipmunk, name: "tl10c.mp4"))
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.audioDuration, 6, accuracy: 0.4)
    }

    func testTimelapseWithoutSound() throws {
        let info = videoInfo(try timelapse(speed: 20, audio: .none, name: "tl20.mp4"))
        XCTAssertEqual(info.duration, 3, accuracy: 0.3)
        XCTAssertFalse(info.hasAudio)
    }

    func testTimelapse100xUsesTwoAudioPasses() throws {
        for mode in [AudioMode.keepPitch, .chipmunk] {
            let info = videoInfo(try timelapse(speed: 100, audio: mode, name: "tl100-\(mode.rawValue).mp4"))
            XCTAssertEqual(info.duration, 0.6, accuracy: 0.15)
            XCTAssertTrue(info.hasAudio, "mode \(mode)")
            XCTAssertEqual(info.audioDuration, 0.6, accuracy: 0.2, "mode \(mode)")
        }
    }

    func testTimelapse400xProducesFrames() throws {
        let info = videoInfo(try timelapse(speed: 400, audio: .keepPitch, name: "tl400.mp4"))
        XCTAssertGreaterThan(info.duration, 0.05)
        XCTAssertLessThan(info.duration, 0.4)
    }

    func testTimelapseNeverUpscales() throws {
        var s = EncodeSettings()
        s.speed = 20
        s.maxHeight = 2160
        let url = out("noupscale.mp4")
        try runJob(Transcoder(urls: Self.clips, output: url, settings: s))
        XCTAssertEqual(videoInfo(url).size, CGSize(width: 320, height: 240))
    }

    // MARK: - Join

    func testLosslessJoinWithTrimAndDate() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09
        let url = out("joined.mp4")
        try runJob(LosslessJoiner(urls: Self.clips, output: url, includeAudio: true, trimStart: 1, trimEnd: 2, recordingDate: date))
        let info = videoInfo(url)
        XCTAssertEqual(info.duration, 57, accuracy: 0.3)
        XCTAssertEqual(info.size, CGSize(width: 320, height: 240))
        XCTAssertTrue(info.hasAudio)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
        let asset = AVURLAsset(url: url)
        let metaDate = asset.creationDate?.dateValue ?? (asset.creationDate?.stringValue).flatMap { ISO8601DateFormatter().date(from: $0) }
        XCTAssertNotNil(metaDate, "creation date metadata missing; items: \(asset.metadata)")
        if let metaDate = metaDate { XCTAssertEqual(metaDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1) }
    }

    func testLosslessJoinWithoutSound() throws {
        let url = out("joined-silent.mp4")
        try runJob(LosslessJoiner(urls: Self.clips, output: url, includeAudio: false, trimStart: 0, trimEnd: 0, recordingDate: nil))
        let info = videoInfo(url)
        XCTAssertEqual(info.duration, 60, accuracy: 0.3)
        XCTAssertFalse(info.hasAudio)
    }

    func testReencodeJoinShrinks() throws {
        var s = EncodeSettings()
        s.speed = 1
        s.maxHeight = 120
        s.fps = 30
        s.audio = .keepPitch
        s.trimEnd = 10
        let url = out("joined-small.mp4")
        try runJob(Transcoder(urls: Self.clips, output: url, settings: s))
        let info = videoInfo(url)
        XCTAssertEqual(info.duration, 50, accuracy: 0.4)
        XCTAssertEqual(info.size, CGSize(width: 160, height: 120))
        XCTAssertTrue(info.hasAudio)
    }

    func testLosslessRejectsMismatchedClips() throws {
        let odd = out("GX010099.MP4")
        try TestClips.make(odd, seconds: 2, width: 640, height: 480, audio: false)
        XCTAssertNotNil(JoinedComposition.losslessIncompatibility([Self.clips[0], odd]))
        XCTAssertNil(JoinedComposition.losslessIncompatibility(Self.clips))
        XCTAssertThrowsError(try LosslessJoiner(urls: [Self.clips[0], odd], output: out("bad.mp4"), includeAudio: true,
                                                trimStart: 0, trimEnd: 0, recordingDate: nil).run())
    }

    func testTrimTooLongIsRejected() {
        var s = EncodeSettings()
        s.trimStart = 30
        s.trimEnd = 30
        XCTAssertThrowsError(try Transcoder(urls: Self.clips, output: out("x.mp4"), settings: s).run())
    }

    /// Not a real test: writes GoPro-named sample clips for the CI screenshot step.
    func testWriteScreenshotClips() throws {
        guard let target = ProcessInfo.processInfo.environment["GPT_SCREENSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: target)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, name) in ["GX010231.MP4", "GX020231.MP4", "GX030231.MP4", "GX010232.MP4", "GX010233.MP4"].enumerated() {
            try TestClips.make(dir.appendingPathComponent(name), seconds: Double(3 + i))
        }
    }
}
