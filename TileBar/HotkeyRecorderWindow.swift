import Cocoa

/// Two-mode hotkey recorder.
/// - `.fullKey`     captures modifier+key combos like ⌘⌥T (used for tile/undo).
/// - `.modifierOnly` captures only the modifier portion like ⌘⌥; the user
///   still presses some main key to confirm but we discard it. Used for
///   the per-display move prefix.
enum HotkeyRecorderMode {
    case fullKey
    case modifierOnly
}

final class HotkeyRecorderWindow: NSWindow {
    private let promptLabel = NSTextField(labelWithString: "请按下你想要的组合键")
    private let captureLabel = NSTextField(labelWithString: "—")
    private let hintLabel = NSTextField(labelWithString: "需要至少包含 ⌘/⌃/⌥/⇧ 中的一个修饰键")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private var mode: HotkeyRecorderMode = .fullKey
    private var capturedSpec: HotkeySpec?
    private var capturedMods: NSEvent.ModifierFlags?
    private var keyMonitor: Any?

    /// Fired when the user saves a full hotkey (mode = .fullKey).
    var onSave: ((HotkeySpec) -> Void)?
    /// Fired when the user saves a modifier-only prefix (mode = .modifierOnly).
    var onSaveModifiers: ((NSEvent.ModifierFlags) -> Void)?

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

    /// Show as full-hotkey recorder. Pre-fills with the current binding.
    func show(currentHotkey: HotkeySpec) {
        mode = .fullKey
        title = "设置平铺快捷键"
        promptLabel.stringValue = "请按下你想要的组合键"
        hintLabel.stringValue = "需要至少包含 ⌘/⌃/⌥/⇧ 中的一个修饰键"
        capturedSpec = currentHotkey
        capturedMods = nil
        captureLabel.stringValue = currentHotkey.displayString()
        captureLabel.textColor = .secondaryLabelColor
        saveButton.isEnabled = false
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        startCapturing()
    }

    /// Show as modifier-only recorder. The user presses any combo; we keep
    /// only the modifier part and discard the main key. Display previews
    /// the prefix with the digit/arrow slot, e.g. ⌘⌥+1/2/←/→.
    func showModifierOnly(currentMods: NSEvent.ModifierFlags) {
        mode = .modifierOnly
        title = "设置移动窗口修饰键"
        promptLabel.stringValue = "按下含修饰键的组合（主键会被忽略）"
        hintLabel.stringValue = "保存后会与数字键 1/2/… 组合成「送到显示器 N」，"
            + "并与方向键 ←/→ 组合成「送到上一个/下一个显示器」"
        capturedSpec = nil
        capturedMods = currentMods
        captureLabel.stringValue = HotkeySpec.displayModifiers(currentMods) + "+1/2/…/←/→"
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

    /// Returns true if the event was consumed.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptable: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let usefulMods = mods.intersection(acceptable)
        let strongMods = usefulMods.intersection([.command, .option, .control])
        guard !strongMods.isEmpty else {
            captureLabel.stringValue = "需要 ⌘/⌃/⌥ 中的至少一个"
            captureLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return true
        }

        switch mode {
        case .fullKey:
            let keyCode = UInt32(event.keyCode)
            guard KeyMap.name(for: keyCode) != nil else {
                captureLabel.stringValue = "不支持这个键"
                captureLabel.textColor = .systemRed
                saveButton.isEnabled = false
                return true
            }
            let spec = HotkeySpec(keyCode: keyCode, modifiers: usefulMods)
            capturedSpec = spec
            captureLabel.stringValue = spec.displayString()

        case .modifierOnly:
            capturedMods = usefulMods
            captureLabel.stringValue = HotkeySpec.displayModifiers(usefulMods) + "+1/2/…/←/→"
        }

        captureLabel.textColor = .labelColor
        saveButton.isEnabled = true
        return true
    }

    @objc private func saveTapped() {
        stopCapturing()
        switch mode {
        case .fullKey:
            if let s = capturedSpec { onSave?(s) }
        case .modifierOnly:
            if let m = capturedMods { onSaveModifiers?(m) }
        }
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
