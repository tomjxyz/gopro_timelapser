import AVFoundation

/// Puts the original recording time on an output so it sorts correctly in Photos, QuickTime and Finder.
public enum OutputMetadata {
    public static func items(for date: Date) -> [AVMetadataItem] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let text = iso.string(from: date)

        let common = AVMutableMetadataItem()
        common.keySpace = .common
        common.key = AVMetadataKey.commonKeyCreationDate as NSString
        common.value = text as NSString

        let quickTime = AVMutableMetadataItem()
        quickTime.identifier = .quickTimeMetadataCreationDate
        quickTime.dataType = kCMMetadataBaseDataType_UTF8 as String
        quickTime.value = text as NSString
        return [common, quickTime]
    }

    public static func setFileDates(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
}
