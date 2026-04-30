import Cocoa

/// A click-to-record button-like control for capturing a hotkey combo.
/// Two modes:
/// - `.fullKey`     captures both modifiers + main key (e.g. ⌘⌥T).
/// - `.modifierOnly` captures only the modifier portion (the main key
///   pressed during recording is discarded). The displayed value is
///   suffixed with `+1/2/…/←/→/↑/↓` to telegraph what it'll combine with.
final class HotkeyField: NSButton {
    enum Mode { case fullKey, modifierOnly }

    let mode: Mode
    private(set) var spec: HotkeySpec?
    private(set) var modifiers: NSEvent.ModifierFlags?

    /// Called right before this field starts capturing. The settings
    /// window uses it to cancel any other field that's currently capturing
    /// — only one field records at a time.
    var onWillStartRecording: (() -> Void)?

    private var isRecording = false
    private var keyMonitor: Any?
    private var savedSpec: HotkeySpec?
    private var savedMods: NSEvent.ModifierFlags?

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        bezelStyle = .roundRect
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        target = self
        action = #selector(handleClick)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        renderIdle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setValue(spec: HotkeySpec? = nil, mods: NSEvent.ModifierFlags? = nil) {
        self.spec = spec
        self.modifiers = mods
        renderIdle()
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        onWillStartRecording?()
        savedSpec = spec
        savedMods = modifiers
        isRecording = true
        renderText(L10n.fieldRecording, color: .systemBlue)

        // Local monitor — intercepts all keyDown events while the settings
        // window is key. Returning nil consumes the event so it doesn't
        // also trigger Save's Return-binding or Cancel's Esc-binding.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        stopRecording()
        spec = savedSpec
        modifiers = savedMods
        renderIdle()
    }

    private func stopRecording() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        isRecording = false
    }

    /// Returns true when the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 0x35 {  // Esc
            cancelRecording()
            return true
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let acceptable: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let usefulMods = mods.intersection(acceptable)
        let strongMods = usefulMods.intersection([.command, .option, .control])
        guard !strongMods.isEmpty else {
            renderText(L10n.fieldNeedModifier, color: .systemRed)
            return true
        }

        switch mode {
        case .fullKey:
            let keyCode = UInt32(event.keyCode)
            guard KeyMap.name(for: keyCode) != nil else {
                renderText(L10n.fieldUnsupported, color: .systemRed)
                return true
            }
            spec = HotkeySpec(keyCode: keyCode, modifiers: usefulMods)
        case .modifierOnly:
            modifiers = usefulMods
        }
        stopRecording()
        renderIdle()
        return true
    }

    // MARK: - Rendering

    private func renderIdle() {
        switch mode {
        case .fullKey:
            if let s = spec { renderText(s.displayString(), color: .labelColor) }
            else { renderText(L10n.fieldEmpty, color: .tertiaryLabelColor) }
        case .modifierOnly:
            if let m = modifiers {
                renderText(HotkeySpec.displayModifiers(m) + L10n.fieldModifierSuffix,
                           color: .labelColor)
            } else {
                renderText(L10n.fieldEmpty, color: .tertiaryLabelColor)
            }
        }
    }

    /// attributedTitle is the only reliable way to color text on a
    /// bezeled NSButton — `contentTintColor` is ignored for most styles.
    private func renderText(_ s: String, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: s, attributes: [
            .foregroundColor: color,
            .font: font ?? .systemFont(ofSize: 14),
            .paragraphStyle: style,
        ])
    }
}

/// Single settings window covering everything the user can customize.
/// Sections (top to bottom): tile hotkey, window-move modifier prefix,
/// Vim-keys checkbox. Save commits all three at once via `onSave`. New
/// settings should slot in here as additional rows.
final class SettingsWindow: NSWindow {
    /// Fired on Save click. Carries everything in the form so the caller
    /// can persist + re-register hotkeys atomically.
    var onSave: ((HotkeySpec, NSEvent.ModifierFlags, Bool) -> Void)?

    private let tileField = HotkeyField(mode: .fullKey)
    private let moveField = HotkeyField(mode: .modifierOnly)
    private let vimCheckbox = NSButton(checkboxWithTitle: L10n.settingsVimCheckbox,
                                       target: nil, action: nil)
    private let saveButton = NSButton(title: L10n.settingsSave, target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.settingsCancel, target: nil, action: nil)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                   styleMask: [.titled, .closable],
                   backing: .buffered,
                   defer: false)
        title = L10n.settingsTitle
        isReleasedWhenClosed = false
        level = .floating
        layoutContent()

        tileField.onWillStartRecording = { [weak self] in self?.moveField.cancelRecording() }
        moveField.onWillStartRecording = { [weak self] in self?.tileField.cancelRecording() }
    }

    /// Pre-fill all fields with the current settings, then surface the window.
    func show(currentTile: HotkeySpec,
              currentMod: NSEvent.ModifierFlags,
              currentVim: Bool) {
        tileField.setValue(spec: currentTile)
        moveField.setValue(mods: currentMod)
        vimCheckbox.state = currentVim ? .on : .off
        center()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    private func layoutContent() {
        guard let content = contentView else { return }

        let tileLabel = makeSectionLabel(L10n.settingsTileHotkeyLabel)
        let moveLabel = makeSectionLabel(L10n.settingsMoveModifierLabel)
        let moveHint = makeHintLabel(L10n.settingsMoveModifierHint)

        vimCheckbox.translatesAutoresizingMaskIntoConstraints = false
        vimCheckbox.font = .systemFont(ofSize: 12)

        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        for v in [tileLabel, tileField, moveLabel, moveField, moveHint, vimCheckbox,
                  saveButton, cancelButton] {
            content.addSubview(v)
        }

        let pad: CGFloat = 20
        NSLayoutConstraint.activate([
            tileLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            tileLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            tileLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            tileField.topAnchor.constraint(equalTo: tileLabel.bottomAnchor, constant: 6),
            tileField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            tileField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            moveLabel.topAnchor.constraint(equalTo: tileField.bottomAnchor, constant: 18),
            moveLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            moveLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            moveField.topAnchor.constraint(equalTo: moveLabel.bottomAnchor, constant: 6),
            moveField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            moveField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            moveHint.topAnchor.constraint(equalTo: moveField.bottomAnchor, constant: 6),
            moveHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            moveHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            vimCheckbox.topAnchor.constraint(equalTo: moveHint.bottomAnchor, constant: 14),
            vimCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),

            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),

            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])
    }

    private func makeSectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func makeHintLabel(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.maximumNumberOfLines = 0
        return l
    }

    @objc private func saveTapped() {
        // Either field may legitimately be empty if the user opened the
        // window without prior config and never finished recording — fall
        // back to defaults rather than silently no-op.
        let spec = tileField.spec ?? .default
        let mods = moveField.modifiers ?? [.command, .option]
        onSave?(spec, mods, vimCheckbox.state == .on)
        close()
    }

    @objc private func cancelTapped() {
        close()
    }

    override func close() {
        tileField.cancelRecording()
        moveField.cancelRecording()
        super.close()
    }
}
