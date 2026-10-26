import AppKit
import TimelapserCore

final class TimelapseTab: NSObject {
    static let minSpeed = 2.0, maxSpeed = 400.0
    static let presets = [2, 5, 10, 20, 40, 60, 100, 200, 400]

    let clips = ClipListView()
    private let speedSlider = NSSlider(value: 0, minValue: 0, maxValue: 1000, target: nil, action: nil)
    private let speedField = NSTextField()
    private let speedStepper = NSStepper()
    private let speedInfo = label("", secondary: true, small: true)
    private var presetButtons: [NSButton] = []
    private let quality = QualityControls(offerSourceFps: false)
    private let sound = NSButton(checkboxWithTitle: "Include sound", target: nil, action: nil)
    private let keepPitch = NSButton(radioButtonWithTitle: "Keep natural pitch", target: nil, action: nil)
    private let chipmunk = NSButton(radioButtonWithTitle: "Chipmunk (pitch rises with speed)", target: nil, action: nil)
    private let output = OutputRow()
    private var run: RunPanel!
    private(set) var view: NSView!

    private(set) var speed: Int = 40

    override init() {
        super.init()
        run = RunPanel(startTitle: "Create Timelapse", startAction: #selector(start), target: self)
        build()
        setSpeed(40)
        updateSound()
        updateState()
    }

    private func build() {
        clips.onChange = { [weak self] in self?.suggestOutput(); self?.updateSpeedInfo(); self?.updateState() }

        // Speed: log-scale slider so 2–20× gets as much travel as 40–400×.
        speedSlider.target = self
        speedSlider.action = #selector(sliderMoved)
        speedSlider.numberOfTickMarks = 11
        let fmt = NumberFormatter()
        fmt.minimum = NSNumber(value: Self.minSpeed)
        fmt.maximum = NSNumber(value: Self.maxSpeed)
        fmt.maximumFractionDigits = 0
        fmt.allowsFloats = false
        speedField.formatter = fmt
        speedField.alignment = .right
        speedField.target = self
        speedField.action = #selector(fieldChanged)
        speedField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        speedStepper.minValue = Self.minSpeed
        speedStepper.maxValue = Self.maxSpeed
        speedStepper.increment = 1
        speedStepper.valueWraps = false
        speedStepper.target = self
        speedStepper.action = #selector(stepperChanged)

        presetButtons = Self.presets.map { p in
            let b = button("\(p)×", self, #selector(presetClicked(_:)))
            b.tag = p
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            return b
        }
        let sliderRow = hstack([speedSlider, speedField, speedStepper, label("× faster")])
        speedSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let presetRow = hstack([label("Presets:", secondary: true, small: true)] + presetButtons, spacing: 4)
        let speedStack = vstack([sliderRow, presetRow, speedInfo], spacing: 6)
        sliderRow.fillWidth(of: speedStack)

        // Sound
        sound.target = self
        sound.action = #selector(soundChanged)
        keepPitch.target = self
        keepPitch.action = #selector(soundChanged)
        chipmunk.target = self
        chipmunk.action = #selector(soundChanged)
        keepPitch.state = .on
        let soundNote = label("Above ~40× the sound becomes very short and choppy.", secondary: true, small: true)
        let soundStack = vstack([hstack([sound, keepPitch, chipmunk], spacing: 16), soundNote], spacing: 4)

        quality.onChange = { [weak self] in self?.suggestOutput() }
        output.onChange = { [weak self] in self?.updateState() }
        run.onRunningChanged = { [weak self] _ in self?.updateState() }

        let clipsBox = box("Clips — drag GoPro files here, then put them in order", clips)
        let stack = vstack([
            clipsBox,
            box("Speed", speedStack),
            box("Quality", quality.view),
            box("Sound", soundStack),
            box("Save as", output.view),
            run.view,
        ], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.distribution = .fill
        for v in stack.arrangedSubviews { v.fillWidth(of: stack) }
        clipsBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        clipsBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view = stack
    }

    // MARK: - Speed

    private func sliderToSpeed(_ v: Double) -> Int {
        Int((Self.minSpeed * pow(Self.maxSpeed / Self.minSpeed, v / 1000)).rounded())
    }

    private func speedToSlider(_ s: Int) -> Double {
        1000 * log(Double(s) / Self.minSpeed) / log(Self.maxSpeed / Self.minSpeed)
    }

    func setSpeed(_ value: Int, fromSlider: Bool = false) {
        speed = max(Int(Self.minSpeed), min(Int(Self.maxSpeed), value))
        if !fromSlider { speedSlider.doubleValue = speedToSlider(speed) }
        speedField.integerValue = speed
        speedStepper.integerValue = speed
        updateSpeedInfo()
        suggestOutput()
    }

    @objc private func sliderMoved() { setSpeed(sliderToSpeed(speedSlider.doubleValue), fromSlider: true) }
    @objc private func fieldChanged() { setSpeed(speedField.integerValue) }
    @objc private func stepperChanged() { setSpeed(speedStepper.integerValue) }
    @objc private func presetClicked(_ sender: NSButton) { setSpeed(sender.tag) }

    private func updateSpeedInfo() {
        var text = "\(speed)× — every second of the timelapse covers \(Self.span(Double(speed))) of footage."
        let total = clips.totalDuration
        if total > 0 { text += "  Timelapse length ≈ \(Format.duration(total / Double(speed)))." }
        speedInfo.stringValue = text
    }

    private static func span(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) s" : s < 3600 ? String(format: "%.1f min", s / 60) : String(format: "%.1f h", s / 3600)
    }

    // MARK: - Sound / state

    @objc private func soundChanged() { updateSound() }

    private func updateSound() {
        let on = sound.state == .on && !run.isRunning
        keepPitch.isEnabled = on
        chipmunk.isEnabled = on
    }

    private func updateState() {
        let idle = !run.isRunning
        clips.isLocked = !idle
        let controls: [NSControl] = [speedSlider, speedField, speedStepper, sound, output.field] + presetButtons
        controls.forEach { $0.isEnabled = idle }
        quality.setEnabled(idle)
        updateSound()
        run.startButton.isEnabled = idle && !clips.clips.isEmpty && output.url != nil
    }

    private func suggestOutput() {
        guard let first = clips.clips.first else { output.reset(); output.suggest(nil); return }
        let stem = first.url.deletingPathExtension().lastPathComponent
        output.suggest(first.url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_timelapse_\(speed)x_\(quality.resolutionTag).mp4"))
    }

    // MARK: - Run

    @objc private func start() {
        let window = view.window
        guard !clips.clips.isEmpty, let out = output.url else { return }
        if clips.clips.contains(where: { $0.url.standardizedFileURL == out.standardizedFileURL }) {
            RunPanel.showError("The output file can't be one of the clips.", window: window)
            return
        }
        guard RunPanel.confirmOverwrite(out, window: window) else { return }
        output.field.stringValue = out.path

        var s = EncodeSettings()
        s.speed = Double(speed)
        quality.apply(to: &s, firstClip: clips.clips.first?.url)
        s.audio = sound.state != .on ? .none : (chipmunk.state == .on ? .chipmunk : .keepPitch)
        let job = Transcoder(urls: clips.clips.map { $0.url }, output: out, settings: s)
        run.run(job, output: out, window: window)
    }

    var isRunning: Bool { run.isRunning }
}
