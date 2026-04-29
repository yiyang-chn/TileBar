import Cocoa

/// Modal-ish recorder window. Activates the app, captures the next valid
/// keystroke (≥1 modifier + a non-modifier key), shows it, and on Save
/// persists to ~/.tilebar.json + re-registers the global hotkey.
final class HotkeyRecorderWindow: NSWindow {
    private let promptLabel = NSTextField(labelWithString: "请按下你想要的组合键")
    private let captureLabel = NSTextField(labelWithString: "—")
    private let hintLabel = NSTextField(labelWithString: "需要至少包含 ⌘/⌃/⌥/⇧ 中的一个修饰键")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private var captured: HotkeySpec?
    private var keyMonitor: Any?
    var onSave: ((HotkeySpec) -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)
        title = "设置快捷键"
        isReleasedWhenClosed = false
        level = .floating
        layoutContent()
    }

    private func layoutContent() {
        guard let content = contentView else { return }

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = .systemFont(ofSize: 13)
        promptLabel.alignment = .center

        captureLabel.translatesAutoresizingMaskIntoConstraints = false
        captureLabel.font = .systemFont(ofSize: 32, weight: .medium)
        captureLabel.alignment = .center
        captureLabel.textColor = .secondaryLabelColor

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.alignment = .center
        hintLabel.textColor = .tertiaryLabelColor

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        content.addSubview(promptLabel)
        content.addSubview(captureLabel)
        content.addSubview(hintLabel)
        content.addSubview(saveButton)
        content.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            promptLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            promptLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            captureLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 16),
            captureLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            captureLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: captureLabel.bottomAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])
    }

    /// Show the recorder, pre-fill it with the current hotkey, and start
    /// capturing keystrokes.
    func show(currentHotkey: HotkeySpec) {
        captured = currentHotkey
        captureLabel.stringValue = currentHotkey.displayString()
        captureLabel.textColor = .secondaryLabelColor
        saveButton.isEnabled = false
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        startCapturing()
    }

    private func startCapturing() {
        stopCapturing()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleKeyEvent(event) {
                return nil  // consume
            }
            return event
        }
    }

    private func stopCapturing() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Returns true if the event was a valid hotkey keystroke (consumed),
    /// false otherwise (let it through to default handling).
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptable: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let usefulMods = mods.intersection(acceptable)
        // Need at least one of cmd/opt/ctrl. shift alone isn't enough as a
        // global hotkey trigger.
        let strongMods = usefulMods.intersection([.command, .option, .control])
        guard !strongMods.isEmpty else {
            captureLabel.stringValue = "需要 ⌘/⌃/⌥ 中的至少一个"
            captureLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return true
        }
        let keyCode = UInt32(event.keyCode)
        guard KeyMap.name(for: keyCode) != nil else {
            captureLabel.stringValue = "不支持这个键"
            captureLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return true
        }
        let spec = HotkeySpec(keyCode: keyCode, modifiers: usefulMods)
        captured = spec
        captureLabel.stringValue = spec.displayString()
        captureLabel.textColor = .labelColor
        saveButton.isEnabled = true
        return true
    }

    @objc private func saveTapped() {
        guard let spec = captured else { return }
        stopCapturing()
        onSave?(spec)
        close()
    }

    @objc private func cancelTapped() {
        stopCapturing()
        close()
    }

    override func close() {
        stopCapturing()
        super.close()
    }
}
