import Foundation

/// One source clip in the list.
public struct Clip: Equatable {
    public let url: URL
    /// Recording time. GoPro stores the camera's wall clock; it is interpreted in the Mac's time zone.
    public let recorded: Date?
    /// Length in seconds.
    public let duration: Double?

    public var name: String { url.lastPathComponent }

    public init(url: URL, recorded: Date?, duration: Double?) {
        self.url = url
        self.recorded = recorded
        self.duration = duration
    }

    /// Reads recording time and duration from the file's MP4 header (fast: no decoding).
    /// Falls back to the file's modification date when the header has no usable time.
    public static func load(_ url: URL) -> Clip {
        let info = MP4Header.read(url)
        var recorded = info.creationWallClock
        if recorded == nil {
            recorded = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        return Clip(url: url, recorded: recorded, duration: info.duration)
    }

    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Expands folders (top level only) and keeps only video files.
    public static func videoFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
                result += items.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    /// Recording order: by time, then by GoPro recording number + chapter.
    public static func recordingOrder(_ a: Clip, _ b: Clip) -> Bool {
        switch (a.recorded, b.recorded) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return goProOrderKey(a.name) < goProOrderKey(b.name)
        }
    }

    /// GoPro names are like GX010123.MP4 / GH010123.MP4 / GOPR0123.MP4: chapter is characters 3-4,
    /// recording number is the last four digits. Sort by recording, then chapter.
    public static func goProOrderKey(_ name: String) -> String {
        let stem = ((name as NSString).deletingPathExtension).uppercased()
        let chars = Array(stem)
        if chars.count == 8, chars[0] == "G", chars[4...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            let chapter = stem.hasPrefix("GOPR") ? "00" : String(chars[2...3])
            return String(chars[4...]) + chapter
        }
        return stem
    }
}

/// Minimal MP4/QuickTime reader for the 'moov/mvhd' box.
public enum MP4Header {
    public struct Info {
        /// Camera wall-clock time converted to a Date in the current time zone.
        public var creationWallClock: Date?
        public var duration: Double?
    }

    public static func read(_ url: URL) -> Info {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Info() }
        defer { try? fh.close() }
        let fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber ?? 0)
        guard let moov = findBox(fh, start: 0, end: fileSize, type: "moov"),
              let mvhd = findBox(fh, start: moov.dataStart, end: moov.end, type: "mvhd") else { return Info() }
        fh.seek(toFileOffset: UInt64(mvhd.dataStart))
        let data = fh.readData(ofLength: 32)
        guard data.count >= 20 else { return Info() }
        let b = [UInt8](data)
        let version = b[0]
        let created: UInt64, timescale: UInt32, duration: UInt64
        if version == 1 {
            guard b.count >= 32 else { return Info() }
            created = be64(b, 4)
            timescale = be32(b, 20)
            duration = be64(b, 24)
        } else {
            created = UInt64(be32(b, 4))
            timescale = be32(b, 12)
            duration = UInt64(be32(b, 16))
        }

        var info = Info()
        if created > 0 {
            // Seconds since 1904-01-01 as a wall-clock reading; rebuild it in the local time zone.
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let epoch1904 = utc.date(from: DateComponents(year: 1904, month: 1, day: 1))!
            let wall = epoch1904.addingTimeInterval(TimeInterval(created))
            let comps = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
            if let year = comps.year, (2000...2100).contains(year) {
                var local = Calendar(identifier: .gregorian)
                local.timeZone = .current
                info.creationWallClock = local.date(from: comps)
            }
        }
        if timescale > 0, duration > 0, duration != UInt64(UInt32.max), duration != UInt64.max {
            info.duration = Double(duration) / Double(timescale)
        }
        return info
    }

    private static func findBox(_ fh: FileHandle, start: Int64, end: Int64, type: String) -> (dataStart: Int64, end: Int64)? {
        var pos = start
        while pos + 8 <= end {
            fh.seek(toFileOffset: UInt64(pos))
            let header = [UInt8](fh.readData(ofLength: 16))
            guard header.count >= 8 else { return nil }
            var size = UInt64(be32(header, 0))
            let boxType = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var headerLen: Int64 = 8
            if size == 1 {
                guard header.count >= 16 else { return nil }
                size = be64(header, 8)
                headerLen = 16
            } else if size == 0 {
                size = UInt64(end - pos)
            }
            guard size >= UInt64(headerLen) else { return nil }
            let boxEnd = pos + Int64(size)
            if boxType == type { return (pos + headerLen, min(boxEnd, end)) }
            pos = boxEnd
        }
        return nil
    }

    private static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        (UInt64(be32(b, o)) << 32) | UInt64(be32(b, o + 4))
    }
}

public enum Format {
    /// 1:05:09 or 4:07
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Parses "90", "1:30" or "1:02:03" into seconds.
    public static func parseDuration(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.trimmingCharacters(in: .whitespaces)), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
