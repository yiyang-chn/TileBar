import Cocoa

/// A transient HUD-style notification: floats near the top-center of
/// the active screen, fades in, lingers, fades out. Non-modal, pass-
/// through clicks. Used when a tile attempt is rolled back so the user
/// gets visible feedback instead of wondering why ⌘⌥T did nothing.
final class Toast: NSPanel {
    private static var current: Toast?
    private static let visibleDuration: TimeInterval = 4.0

    /// Convenience: show a single toast. Replaces any prior toast that
    /// might still be on screen.
    static func show(title: String, body: String, symbol: String = "exclamationmark.triangle.fill") {
        Toast.current?.dismiss()
        let t = Toast(title: title, body: body, symbol: symbol)
        Toast.current = t
        t.present()
    }

    init(title: String, body: String, symbol: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 130),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        // Floating, no focus, click-through, present on every Space so
        // the user sees it even when they ⌘⌥T from full-screen apps.
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .utilityWindow

        layoutContent(title: title, body: body, symbol: symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func layoutContent(title: String, body: String, symbol: String) {
        guard let cv = contentView else { return }
        cv.wantsLayer = true

        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        cv.addSubview(blur)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = .systemOrange

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 3

        // Title + body stacked vertically as a unit, then the unit is
        // vertically centered against the icon. Anchoring title to blur.top
        // (the previous setup) left the text floating above the icon's
        // vertical centerline, looking misaligned.
        let textStack = NSStackView(views: [titleLabel, bodyLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        blur.addSubview(icon)
        blur.addSubview(textStack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: cv.topAnchor),
            blur.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: cv.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 18),
            textStack.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -22),
            textStack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: blur.topAnchor, constant: 16),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: blur.bottomAnchor, constant: -16),
        ])
    }

    private func present() {
        // Dead-center of the screen the user is most likely looking at —
        // the one with key window, falling back to main.
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let s = screen else { return }
        let vf = s.visibleFrame
        let w = self.frame.width
        let h = self.frame.height
        setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.midY - h / 2))

        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { [weak self] in
            self?.dismiss()
        }
    }

    fileprivate func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.orderOut(nil)
            if Toast.current === self { Toast.current = nil }
        })
    }
}
