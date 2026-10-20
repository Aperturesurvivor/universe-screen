// Layer 3 — UI: NSPopover content with sliders for all simulation variables.
import AppKit

@MainActor
final class ControlPanelViewController: NSViewController {

    private let config: SimulationConfig
    private let onQuit: () -> Void
    private let onResetAndRetry: () -> Void
    private let onGamifiedToggle: (Bool) -> Void
    private let onStarChange: () -> Void
    private let onSeedChange: (UInt64) -> Void

    // Sky / seed
    private let seedSlider = NSSlider()
    private let seedValueLabel = NSTextField(labelWithString: "")

    // Motion
    private let motionSlider = NSSlider()
    private let motionLabel  = NSTextField(labelWithString: "")

    // Star
    private let temperatureSlider  = NSSlider()
    private let intensitySlider    = NSSlider()
    private let stabilitySlider    = NSSlider()
    private let coronaSlider       = NSSlider()
    private let flareDensitySlider = NSSlider()

    private let temperatureLabel  = NSTextField(labelWithString: "")
    private let intensityLabel    = NSTextField(labelWithString: "")
    private let stabilityLabel    = NSTextField(labelWithString: "")
    private let coronaLabel       = NSTextField(labelWithString: "")
    private let flareDensityLabel = NSTextField(labelWithString: "")

    // Gamified + status
    private let gamifiedToggle = NSButton(checkboxWithTitle: "Gamified Mode (cover desktop icons)",
                                          target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let seedLabel   = NSTextField(labelWithString: "")
    private let finderLabel = NSTextField(labelWithString: "")

    private let openSettingsButton = NSButton(title: "Open Privacy Settings",
                                              target: nil, action: nil)
    private let resetAccessButton  = NSButton(title: "Reset Finder access & retry",
                                              target: nil, action: nil)

    /// The slider sweeps integer positions in [0, seedSliderMax]. The integer is
    /// cast directly to the universe seed so each tick is reproducible and the
    /// resulting seed displayString stays short and shareable.
    static let seedSliderMax: Int = 100_000

    init(config: SimulationConfig,
         onQuit: @escaping () -> Void,
         onResetAndRetry: @escaping () -> Void,
         onGamifiedToggle: @escaping (Bool) -> Void,
         onStarChange: @escaping () -> Void,
         onSeedChange: @escaping (UInt64) -> Void) {
        self.config           = config
        self.onQuit           = onQuit
        self.onResetAndRetry  = onResetAndRetry
        self.onGamifiedToggle = onGamifiedToggle
        self.onStarChange     = onStarChange
        self.onSeedChange     = onSeedChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Seed slider — initialized in setInitialSeed(_:) once AppDelegate has
        // loaded the persisted seed. Range is large enough for casual scrubbing
        // without exposing every UInt64 value (which a slider can't represent).
        configure(seedSlider, min: 0, max: Double(Self.seedSliderMax),
                  value: 0, action: #selector(seedChanged))

        // Motion
        configure(motionSlider, min: 0, max: 2,
                  value: Double(config.motionAmount), action: #selector(motionChanged))

        // Star sliders
        configure(temperatureSlider,  min: 0, max: 1,
                  value: Double(config.starTemperature),  action: #selector(temperatureChanged))
        configure(intensitySlider,    min: 0, max: 1,
                  value: Double(config.starIntensity),    action: #selector(intensityChanged))
        configure(stabilitySlider,    min: 0, max: 1,
                  value: Double(config.starStability),    action: #selector(stabilityChanged))
        configure(coronaSlider,       min: 0.3, max: 2.0,
                  value: Double(config.starCoronaScale),  action: #selector(coronaChanged))
        configure(flareDensitySlider, min: 0, max: 1,
                  value: Double(config.starFlareDensity), action: #selector(flareDensityChanged))

        // Gamified
        gamifiedToggle.state  = config.gamifiedMode ? .on : .off
        gamifiedToggle.target = self
        gamifiedToggle.action = #selector(gamifiedChanged)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitBtn.bezelStyle = .rounded
        openSettingsButton.target = self; openSettingsButton.action = #selector(openSettings)
        openSettingsButton.bezelStyle = .rounded
        resetAccessButton.target  = self; resetAccessButton.action  = #selector(resetAccess)
        resetAccessButton.bezelStyle = .rounded

        // ---- Title & status labels ----
        let title = label("Universe Screen", bold: true, size: 13)
        title.frame = NSRect(x: 16, y: 570, width: 290, height: 20)
        view.addSubview(title)

        statusLabel.frame     = NSRect(x: 16, y: 552, width: 290, height: 16)
        statusLabel.font      = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        view.addSubview(statusLabel)

        seedLabel.frame     = NSRect(x: 16, y: 534, width: 290, height: 16)
        seedLabel.font      = .systemFont(ofSize: 10)
        seedLabel.textColor = .secondaryLabelColor
        view.addSubview(seedLabel)

        finderLabel.frame = NSRect(x: 16, y: 514, width: 290, height: 16)
        finderLabel.font  = .systemFont(ofSize: 10)
        view.addSubview(finderLabel)

        // ---- Sky section ----
        let skyHeader = label("Sky", bold: true, size: 11)
        skyHeader.frame = NSRect(x: 16, y: 494, width: 290, height: 14)
        view.addSubview(skyHeader)

        addSliderRow(nameText: "Seed",
                     nameY: 476, sliderY: 454,
                     slider: seedSlider, valueLabel: seedValueLabel)

        // ---- Star Controls section ----
        let starHeader = label("Star", bold: true, size: 11)
        starHeader.frame = NSRect(x: 16, y: 430, width: 290, height: 14)
        view.addSubview(starHeader)

        addSliderRow(nameText: "Temperature",
                     nameY: 412, sliderY: 390,
                     slider: temperatureSlider, valueLabel: temperatureLabel)

        addSliderRow(nameText: "Intensity",
                     nameY: 366, sliderY: 344,
                     slider: intensitySlider, valueLabel: intensityLabel)

        addSliderRow(nameText: "Stability",
                     nameY: 320, sliderY: 298,
                     slider: stabilitySlider, valueLabel: stabilityLabel)

        addSliderRow(nameText: "Corona Scale",
                     nameY: 274, sliderY: 252,
                     slider: coronaSlider, valueLabel: coronaLabel)

        addSliderRow(nameText: "Flare Density",
                     nameY: 228, sliderY: 206,
                     slider: flareDensitySlider, valueLabel: flareDensityLabel)

        // ---- Motion section ----
        addSliderRow(nameText: "Motion",
                     nameY: 182, sliderY: 160,
                     slider: motionSlider, valueLabel: motionLabel)

        // ---- Gamified + buttons ----
        gamifiedToggle.frame = NSRect(x: 16, y: 130, width: 290, height: 22)
        view.addSubview(gamifiedToggle)

        openSettingsButton.frame = NSRect(x: 16, y: 94, width: 290, height: 24)
        view.addSubview(openSettingsButton)

        resetAccessButton.frame  = NSRect(x: 16, y: 58, width: 290, height: 24)
        view.addSubview(resetAccessButton)

        quitBtn.frame = NSRect(x: 16, y: 12, width: 80, height: 24)
        view.addSubview(quitBtn)

        refreshLabels()
    }

    var seedDisplay: String = ""

    /// Called once at launch so the slider starts at a position that produces
    /// the persisted seed (modulo the slider's range). Seeds outside the range
    /// fall back to value 0 — the displayString shown in the status label is
    /// still the real seed.
    func setInitialSeed(_ seed: Seed) {
        seedDisplay = seed.displayString
        let pos = Int(seed.value % UInt64(Self.seedSliderMax + 1))
        seedSlider.intValue = Int32(pos)
        seedValueLabel.stringValue = seed.displayString
    }

    func refreshLabels() {
        motionLabel.stringValue       = String(format: "%.2f", config.motionAmount)
        temperatureLabel.stringValue  = String(format: "%.2f", config.starTemperature)
        intensityLabel.stringValue    = String(format: "%.2f", config.starIntensity)
        stabilityLabel.stringValue    = String(format: "%.2f", config.starStability)
        coronaLabel.stringValue       = String(format: "%.2f", config.starCoronaScale)
        flareDensityLabel.stringValue = String(format: "%.2f", config.starFlareDensity)

        temperatureSlider.doubleValue  = Double(config.starTemperature)
        intensitySlider.doubleValue    = Double(config.starIntensity)
        stabilitySlider.doubleValue    = Double(config.starStability)
        coronaSlider.doubleValue       = Double(config.starCoronaScale)
        flareDensitySlider.doubleValue = Double(config.starFlareDensity)

        statusLabel.stringValue = "\(config.planetCount) planets · \(config.asteroidCount) asteroids · positions: \(config.positionSource)"
        seedLabel.stringValue   = "Seed: \(seedDisplay)"
        seedValueLabel.stringValue = seedDisplay

        let finderColor: NSColor
        let finderText: String
        if FinderFetchState.lastResultCount > 0 {
            finderText  = "Finder OK · \(FinderFetchState.lastResultCount) icons read"
            finderColor = .systemGreen
        } else if FinderFetchState.lastErrorCode != 0 {
            finderText  = "Finder access not granted (\(FinderFetchState.lastErrorCode)) — use the buttons below"
            finderColor = .systemOrange
        } else {
            finderText  = "Finder returned 0 icons — try the buttons below"
            finderColor = .systemOrange
        }
        finderLabel.stringValue = finderText
        finderLabel.textColor   = finderColor
    }

    // MARK: - Actions

    @objc private func seedChanged() {
        let newValue = UInt64(seedSlider.intValue)
        let newSeed  = Seed(value: newValue)
        seedDisplay = newSeed.displayString
        seedLabel.stringValue       = "Seed: \(seedDisplay)"
        seedValueLabel.stringValue  = seedDisplay
        onSeedChange(newValue)
    }
    @objc private func motionChanged() {
        config.motionAmount = Float(motionSlider.doubleValue)
        motionLabel.stringValue = String(format: "%.2f", config.motionAmount)
    }
    @objc private func temperatureChanged() {
        config.starTemperature = Float(temperatureSlider.doubleValue)
        temperatureLabel.stringValue = String(format: "%.2f", config.starTemperature)
        onStarChange()
    }
    @objc private func intensityChanged() {
        config.starIntensity = Float(intensitySlider.doubleValue)
        intensityLabel.stringValue = String(format: "%.2f", config.starIntensity)
        onStarChange()
    }
    @objc private func stabilityChanged() {
        config.starStability = Float(stabilitySlider.doubleValue)
        stabilityLabel.stringValue = String(format: "%.2f", config.starStability)
        onStarChange()
    }
    @objc private func coronaChanged() {
        config.starCoronaScale = Float(coronaSlider.doubleValue)
        coronaLabel.stringValue = String(format: "%.2f", config.starCoronaScale)
        onStarChange()
    }
    @objc private func flareDensityChanged() {
        config.starFlareDensity = Float(flareDensitySlider.doubleValue)
        flareDensityLabel.stringValue = String(format: "%.2f", config.starFlareDensity)
        onStarChange()
    }
    @objc private func gamifiedChanged() {
        let on = (gamifiedToggle.state == .on)
        config.gamifiedMode = on
        onGamifiedToggle(on)
    }
    @objc private func quit() { onQuit() }
    @objc private func openSettings() {
        FinderIconPositions.openAutomationSettings()
    }
    @objc private func resetAccess() {
        FinderIconPositions.resetAppleEventsPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.onResetAndRetry()
            self?.refreshLabels()
        }
    }

    // MARK: - Layout helpers

    private func addSliderRow(nameText: String, nameY: Int, sliderY: Int,
                              slider: NSSlider, valueLabel: NSTextField) {
        let n = label(nameText, bold: false, size: 11)
        n.frame = NSRect(x: 16, y: nameY, width: 180, height: 16)
        valueLabel.frame     = NSRect(x: 200, y: nameY, width: 104, height: 16)
        valueLabel.alignment = .right
        valueLabel.font      = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        slider.frame         = NSRect(x: 16, y: sliderY, width: 290, height: 22)
        view.addSubview(n); view.addSubview(valueLabel); view.addSubview(slider)
    }

    private func configure(_ s: NSSlider, min: Double, max: Double,
                           value: Double, action: Selector) {
        s.minValue    = min; s.maxValue = max
        s.doubleValue = value
        s.target = self; s.action = action
    }

    private func label(_ text: String, bold: Bool, size: CGFloat) -> NSTextField {
        let f  = NSTextField(labelWithString: text)
        f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return f
    }
}
