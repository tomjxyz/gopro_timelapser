import AppKit
import TimelapserCore

/// Joins clips at normal speed: losslessly (default) or re-encoded to shrink them.
final class JoinTab: NSObject, NSTextFieldDelegate {
    let clips = ClipListView()
    private let lossless = NSButton(radioButtonWithTitle: "Lossless — fast, no quality loss (clips must match)", target: nil, action: nil)
    private let reencode = NSButton(radioButtonWithTitle: "Re-encode — shrink / change resolution", target: nil, action: nil)
    private let quality = QualityControls(offerSourceFps: true)
    private let sound = NSButton(checkboxWithTitle: "Include sound", target: nil, action: nil)
    private let keepDate = NSButton(checkboxWithTitle: "Keep original recording date", target: nil, action: nil)
    private let trimStart = NSTextField()
    private let trimEnd = NSTextField()
    private let trimInfo = label("", secondary: true, small: true)
    private let output = OutputRow()
    private var run: RunPanel!
    private(set) var view: NSView!

    override init() {
        super.init()
        run = RunPanel(startTitle: "Join Clips", startAction: #selector(start), target: self)
        build()
        updateState()
    }

    private func build() {
        clips.onChange = { [weak self] in self?.suggestOutput(); self?.updateTrimInfo(); self?.updateState() }

        lossless.state = .on
        for b in [lossless, reencode] {
            b.target = self
            b.action = #selector(modeChanged)
        }
        let modeStack = vstack([lossless, reencode, quality.view], spacing: 6)

        sound.state = .on
        keepDate.state = .on
        keepDate.toolTip = "Gives the joined video the first clip's recording time, so it sorts correctly in Photos and Finder."
        for f in [trimStart, trimEnd] {
            f.placeholderString = "0:00"
            f.alignment = .right
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
            f.toolTip = "Seconds or minutes:seconds, e.g. 15 or 1:30"
        }
        let trimRow = hstack([label("Cut from start:"), trimStart, label("   Cut from end:"), trimEnd, trimInfo])
        let optionsStack = vstack([hstack([sound, keepDate], spacing: 20), trimRow], spacing: 8)

        output.onChange = { [weak self] in self?.updateState() }
        run.onRunningChanged = { [weak self] _ in self?.updateState() }

        let clipsBox = box("Clips — drag GoPro files here, then put them in order", clips)
        let stack = vstack([
            clipsBox,
            box("Mode", modeStack),
            box("Options", optionsStack),
            box("Save as", output.view),
            run.view,
        ], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for v in stack.arrangedSubviews { v.fillWidth(of: stack) }
        clipsBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        clipsBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view = stack
    }

    @objc private func modeChanged() { updateState(); suggestOutput() }

    func controlTextDidChange(_ obj: Notification) { updateTrimInfo() }

    private var trims: (start: Double, end: Double)? {
        guard let s = Format.parseDuration(trimStart.stringValue),
              let e = Format.parseDuration(trimEnd.stringValue) else { return nil }
        return (s, e)
    }

    private func updateTrimInfo() {
        let total = clips.totalDuration
        guard let t = trims else { trimInfo.stringValue = "   Use seconds or m:ss"; return }
        guard total > 0 else { trimInfo.stringValue = ""; return }
        let left = total - t.start - t.end
        trimInfo.stringValue = left > 0 ? "   Result ≈ \(Format.duration(left)) of \(Format.duration(total))" : "   Nothing would be left!"
    }

    private func updateState() {
        let idle = !run.isRunning
        clips.isLocked = !idle
        ([lossless, reencode, sound, keepDate, trimStart, trimEnd, output.field] as [NSControl]).forEach { $0.isEnabled = idle }
        quality.setEnabled(idle && reencode.state == .on)
        run.startButton.isEnabled = idle && !clips.clips.isEmpty && output.url != nil
    }

    private func suggestOutput() {
        guard let first = clips.clips.first else { output.reset(); output.suggest(nil); return }
        let stem = first.url.deletingPathExtension().lastPathComponent
        output.suggest(first.url.deletingLastPathComponent().appendingPathComponent("\(stem)_joined.mp4"))
    }

    @objc private func start() {
        let window = view.window
        guard !clips.clips.isEmpty, let out = output.url else { return }
        guard let t = trims else {
            RunPanel.showError("The trim times should be seconds (e.g. 15) or minutes:seconds (e.g. 1:30).", window: window)
            return
        }
        if clips.totalDuration > 0 && t.start + t.end >= clips.totalDuration {
            RunPanel.showError("Trimming \(Format.duration(t.start + t.end)) would leave nothing of the \(Format.duration(clips.totalDuration)) video.", window: window)
            return
        }
        if clips.clips.contains(where: { $0.url.standardizedFileURL == out.standardizedFileURL }) {
            RunPanel.showError("The output file can't be one of the clips.", window: window)
            return
        }
        guard RunPanel.confirmOverwrite(out, window: window) else { return }
        output.field.stringValue = out.path

        let urls = clips.clips.map { $0.url }
        let date = keepDate.state == .on ? clips.clips.first?.recorded : nil
        let job: MediaJob
        if lossless.state == .on {
            job = LosslessJoiner(urls: urls, output: out, includeAudio: sound.state == .on,
                                 trimStart: t.start, trimEnd: t.end, recordingDate: date)
        } else {
            var s = EncodeSettings()
            s.speed = 1
            quality.apply(to: &s, firstClip: urls.first)
            s.audio = sound.state == .on ? .keepPitch : .none
            s.trimStart = t.start
            s.trimEnd = t.end
            s.recordingDate = date
            job = Transcoder(urls: urls, output: out, settings: s)
        }
        run.run(job, output: out, window: window)
    }

    var isRunning: Bool { run.isRunning }
}
