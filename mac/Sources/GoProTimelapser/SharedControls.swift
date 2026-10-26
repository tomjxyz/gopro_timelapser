import AppKit
import AVFoundation
import TimelapserCore

/// Resolution / quality / frame rate / codec, shared by both tabs.
final class QualityControls: NSObject {
    static let resolutions: [(String, Int?)] = [("720p", 720), ("1080p", 1080), ("1440p", 1440), ("4K (2160p)", 2160), ("Original", nil)]

    let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    let fps = NSPopUpButton(frame: .zero, pullsDown: false)
    let codec = NSPopUpButton(frame: .zero, pullsDown: false)
    let quality = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let qualityValue = label("")
    private let offerSourceFps: Bool
    private(set) var view: NSView!
    var onChange: (() -> Void)?

    init(offerSourceFps: Bool) {
        self.offerSourceFps = offerSourceFps
        super.init()

        resolution.addItems(withTitles: Self.resolutions.map { $0.0 })
        resolution.selectItem(at: 1)
        fps.addItems(withTitles: (offerSourceFps ? ["Same as clips"] : []) + ["24", "25", "30", "50", "60"])
        fps.selectItem(withTitle: offerSourceFps ? "Same as clips" : "30")
        codec.addItems(withTitles: ["H.264 (most compatible)", "HEVC / H.265 (smaller files)"])
        codec.toolTip = "HEVC files are about 40% smaller. Macs from before 2017 have no HEVC hardware encoder, so HEVC is much slower there."
        quality.numberOfTickMarks = 11
        quality.allowsTickMarkValuesOnly = false
        for c in [resolution, fps, codec, quality] as [NSControl] {
            c.target = self
            c.action = #selector(changed)
        }

        let qualityRow = hstack([label("Smaller file", secondary: true, small: true), quality,
                                 label("Better quality", secondary: true, small: true), qualityValue])
        quality.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        qualityValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let grid = NSGridView(views: [
            [label("Resolution:"), hstack([resolution, label("   Frame rate:"), fps, label("   Codec:"), codec])],
            [label("Quality:"), qualityRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        view = grid
        updateLabel()
    }

    @objc private func changed() {
        updateLabel()
        onChange?()
    }

    private func updateLabel() {
        let q = quality.doubleValue
        let word = q < 0.2 ? "very low" : q < 0.4 ? "low" : q < 0.6 ? "medium" : q < 0.8 ? "high" : "very high"
        var s = EncodeSettings()
        s.quality = q
        s.fps = 30
        s.codec = codec.indexOfSelectedItem == 1 ? .hevc : .h264
        let mbps = Double(s.bitrate(width: 1920, height: 1080)) / 1_000_000
        qualityValue.stringValue = String(format: "%@  (≈%.1f Mbit/s at 1080p30)", word, mbps)
    }

    var maxHeight: Int? { Self.resolutions[max(0, resolution.indexOfSelectedItem)].1 }

    var resolutionTag: String { maxHeight.map { "\($0)p" } ?? "orig" }

    /// Fills the video settings; "Same as clips" reads the first clip's frame rate.
    func apply(to s: inout EncodeSettings, firstClip: URL?) {
        s.maxHeight = maxHeight
        s.quality = quality.doubleValue
        s.codec = codec.indexOfSelectedItem == 1 ? .hevc : .h264
        if let n = Int(fps.titleOfSelectedItem ?? "") {
            s.fps = n
        } else {
            var rate = 30
            if let url = firstClip, let track = AVURLAsset(url: url).tracks(withMediaType: .video).first {
                let r = Int(track.nominalFrameRate.rounded())
                if r > 0 { rate = min(r, 240) }
            }
            s.fps = rate
        }
    }

    func setEnabled(_ enabled: Bool) {
        [resolution, fps, codec, quality].forEach { $0.isEnabled = enabled }
    }
}

/// Output path with a Save panel. Suggests a name until the user picks one themselves.
final class OutputRow: NSObject, NSTextFieldDelegate {
    let field = NSTextField()
    private(set) var view: NSView!
    private var userChosen = false
    var onChange: (() -> Void)?

    override init() {
        super.init()
        field.placeholderString = "Choose where to save the video"
        field.lineBreakMode = .byTruncatingHead
        field.delegate = self
        let browse = button("Choose…", self, #selector(browse))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view = hstack([field, browse])
    }

    var url: URL? {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        if url.pathExtension.lowercased() != "mp4" { url.appendPathExtension("mp4") }
        return url
    }

    func suggest(_ url: URL?) {
        guard !userChosen else { return }
        field.stringValue = url?.path ?? ""
        onChange?()
    }

    func reset() {
        userChosen = false
    }

    func controlTextDidChange(_ obj: Notification) {
        userChosen = true
        onChange?()
    }

    @objc private func browse() {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["mp4"]
        panel.canCreateDirectories = true
        if let current = url {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.field.stringValue = url.path
            self.userChosen = true
            self.onChange?()
        }
    }
}

/// Start / Cancel / progress / status / log, and running a MediaJob in the background.
final class RunPanel: NSObject {
    let startButton: NSButton
    private let cancelButton: NSButton
    private let progress = NSProgressIndicator()
    private let status = label("Ready.", secondary: true, small: true)
    private let logToggle: NSButton
    private let logScroll = NSScrollView()
    private let logText = NSTextView()
    private var logHeight: NSLayoutConstraint!
    private(set) var view: NSView!
    private var job: MediaJob?

    var isRunning: Bool { job != nil }
    var onRunningChanged: ((Bool) -> Void)?

    init(startTitle: String, startAction: Selector, target: AnyObject) {
        startButton = button(startTitle, target, startAction)
        startButton.keyEquivalent = "\r"
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        logToggle = NSButton(checkboxWithTitle: "Show log", target: nil, action: nil)
        super.init()

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.isEnabled = false
        logToggle.target = self
        logToggle.action = #selector(toggleLog)

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        logText.isEditable = false
        logText.font = NSFont.userFixedPitchFont(ofSize: 11)
        logText.isVerticallyResizable = true
        logText.autoresizingMask = [.width]
        logScroll.documentView = logText
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        logHeight = logScroll.heightAnchor.constraint(equalToConstant: 140)
        logHeight.isActive = true

        let top = hstack([startButton, cancelButton, progress, logToggle])
        let stack = vstack([top, status, logScroll], spacing: 6)
        top.fillWidth(of: stack)
        status.fillWidth(of: stack)
        logScroll.fillWidth(of: stack)
        view = stack
    }

    @objc private func toggleLog() {
        logScroll.isHidden = logToggle.state != .on
    }

    @objc private func cancel() {
        status.stringValue = "Cancelling…"
        job?.cancel()
    }

    func appendLog(_ line: String) {
        let text = NSAttributedString(string: line + "\n", attributes: [
            .font: NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.textColor,
        ])
        logText.textStorage?.append(text)
        logText.scrollToEndOfDocument(nil)
    }

    /// Runs the job on a background queue and reports the outcome in a sheet.
    func run(_ job: MediaJob, output: URL, window: NSWindow?) {
        self.job = job
        logText.string = ""
        progress.doubleValue = 0
        status.stringValue = "Starting…"
        cancelButton.isEnabled = true
        startButton.isEnabled = false
        onRunningChanged?(true)
        appendLog("Output: \(output.path)")

        job.onLog = { [weak self] line in DispatchQueue.main.async { self?.appendLog(line) } }
        job.onProgress = { [weak self] p, text in
            DispatchQueue.main.async {
                self?.progress.doubleValue = p
                self?.status.stringValue = text
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try job.run() } catch { failure = error }
            DispatchQueue.main.async { self.finish(failure, output: output, window: window) }
        }
    }

    private func finish(_ error: Error?, output: URL, window: NSWindow?) {
        job = nil
        cancelButton.isEnabled = false
        startButton.isEnabled = true
        onRunningChanged?(false)

        let alert = NSAlert()
        if error is JobCancelled {
            progress.doubleValue = 0
            status.stringValue = "Cancelled."
            return
        } else if let error = error {
            progress.doubleValue = 0
            status.stringValue = "Failed: \(error.localizedDescription)"
            appendLog("ERROR: \(error.localizedDescription)")
            logToggle.state = .on
            toggleLog()
            alert.alertStyle = .warning
            alert.messageText = "Something went wrong"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        } else {
            progress.doubleValue = 1
            appendLog("Done.")
            alert.messageText = "Your video is ready"
            alert.informativeText = output.path
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Done")
        }
        let succeeded = error == nil
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if succeeded && response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
        }
        if let window = window { alert.beginSheetModal(for: window, completionHandler: handler) } else { handler(alert.runModal()) }
    }

    /// Asks before replacing an existing file. Returns false if the user says no.
    static func confirmOverwrite(_ url: URL, window: NSWindow?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let alert = NSAlert()
        alert.messageText = "\"\(url.lastPathComponent)\" already exists."
        alert.informativeText = "Do you want to replace it?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showError(_ message: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let window = window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }
}
