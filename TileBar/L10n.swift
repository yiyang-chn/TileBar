import Foundation

/// Lightweight bilingual string table. System language is detected once at
/// startup; every UI string is a static computed property that picks the
/// right language. No `Localizable.strings`, no `.lproj/`, no resource
/// bundles — for a menu-bar app with ~30 strings the overhead isn't worth
/// it. Add new strings here, reference everywhere.
enum L10n {
    enum Lang { case zh, en }

    /// Resolved once at process start. Re-launching after switching the
    /// system language picks up the change. (NSApp re-localizes its own
    /// chrome on language change but we're not built on that machinery.)
    static let lang: Lang = {
        guard let preferred = Locale.preferredLanguages.first else { return .en }
        return preferred.lowercased().hasPrefix("zh") ? .zh : .en
    }()

    private static func s(_ zh: String, _ en: String) -> String {
        lang == .zh ? zh : en
    }

    // MARK: - Menu

    static var menuTileNow: String { s("立即平铺", "Tile Now") }
    static func menuMoveToDisplay(_ n: Int) -> String {
        s("把焦点窗口送到显示器 \(n)",
          "Move Focused Window to Display \(n)")
    }
    static var menuMoveLeft: String  { s("把焦点窗口送到左侧显示器", "Move Focused Window Left") }
    static var menuMoveRight: String { s("把焦点窗口送到右侧显示器", "Move Focused Window Right") }
    static var menuMoveUp: String    { s("把焦点窗口送到上方显示器", "Move Focused Window Up") }
    static var menuMoveDown: String  { s("把焦点窗口送到下方显示器", "Move Focused Window Down") }
    static var menuSettings: String  { s("设置…",                    "Settings…") }
    static var menuQuit: String      { s("退出 TileBar",              "Quit TileBar") }

    // MARK: - Accessibility permission alert

    static var axTitle: String        { s("TileBar 需要 Accessibility 权限",
                                          "TileBar Needs Accessibility Permission") }
    static var axBody: String         { s("请在『系统设置 → 隐私与安全性 → 辅助功能』中勾选 TileBar，然后回到这里。",
                                          "Enable TileBar in System Settings → Privacy & Security → Accessibility, then come back here.") }
    static var axOpenSettings: String { s("打开系统设置", "Open System Settings") }
    static var axLater: String        { s("稍后",         "Later") }

    // MARK: - Settings window

    static var settingsTitle: String              { s("TileBar 设置", "TileBar Settings") }
    static var settingsTileHotkeyLabel: String    { s("平铺快捷键",   "Tile Hotkey") }
    static var settingsMoveModifierLabel: String  { s("移动窗口修饰键", "Window Move Modifier") }
    static var settingsMoveModifierHint: String   {
        s("与数字键 1/2/… 组合成「送到显示器 N」；与方向键 ←/→/↑/↓ 组合成「送到对应方向上的显示器」",
          "Combined with 1/2/… sends a window to display N; combined with ←/→/↑/↓ sends it in that direction.")
    }
    static var settingsVimCheckbox: String        { s("启用 HJKL 方向键 (Vim 风格)",
                                                      "Enable HJKL Directional Keys (Vim-style)") }
    static var settingsSave: String               { s("保存", "Save") }
    static var settingsCancel: String             { s("取消", "Cancel") }

    // MARK: - HotkeyField placeholders

    static var fieldClickToRecord: String { s("点击此处录制", "Click to record") }
    static var fieldRecording: String     { s("请按下组合键…", "Press a key combo…") }
    static var fieldNeedModifier: String  { s("需要 ⌘/⌃/⌥ 中至少一个", "Requires at least one of ⌘/⌃/⌥") }
    static var fieldUnsupported: String   { s("不支持这个键", "Unsupported key") }
    static var fieldEmpty: String         { s("未设置", "Not set") }
    static var fieldModifierSuffix: String { "+1/2/…/←/→/↑/↓" }
}
