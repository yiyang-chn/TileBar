import Foundation
import Cocoa

/// Persistent user config at ~/.tilebar.json. Currently the tile hotkey and
/// the modifier prefix used for "move focused window to display N" hotkeys.
struct AppConfig: Codable {
    var hotkey: String
    /// Modifier-only string like "cmd+opt". Combined at runtime with digit
    /// keys 1..N (where N = display count) to form per-display hotkeys.
    /// Optional in JSON for forward compatibility — old configs that
    /// predate this field still load fine and pick up the default.
    var moveToDisplayPrefix: String?
    /// When true, also register `prefix + h/j/k/l` as Vim-style directional
    /// moves (h=left, j=down, k=up, l=right) alongside `prefix + ←/→/↑/↓`.
    /// Off by default — opt-in via the recorder window's checkbox.
    var enableVimKeys: Bool?

    static let `default` = AppConfig(
        hotkey: HotkeySpec.default.configString(),
        moveToDisplayPrefix: "cmd+opt",
        enableVimKeys: false
    )
}

enum AppConfigStore {
    static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".tilebar.json")
    }

    /// Read config from disk. Returns the default config if the file is
    /// missing or malformed; logs the reason in the latter case.
    static func load() -> AppConfig {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            let cfg = try JSONDecoder().decode(AppConfig.self, from: data)
            return cfg
        } catch {
            Logger.log("config load failed: \(error.localizedDescription); using default")
            return .default
        }
    }

    /// Atomically write `config` to ~/.tilebar.json.
    static func save(_ config: AppConfig) {
        let url = fileURL
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(config)
            try data.write(to: url, options: .atomic)
            Logger.log("config saved to \(url.path)")
        } catch {
            Logger.log("config save failed: \(error.localizedDescription)")
        }
    }

    /// Resolve the config's hotkey to a HotkeySpec, falling back to the
    /// default if the string is unparseable.
    static func resolveHotkey(_ config: AppConfig) -> HotkeySpec {
        if let s = HotkeySpec.parse(config.hotkey) { return s }
        Logger.log("invalid hotkey '\(config.hotkey)', using default")
        return .default
    }

    /// Resolve the modifier prefix used for per-display move hotkeys.
    /// Falls back to cmd+opt on parse failure or missing field.
    static func resolveDisplayPrefix(_ config: AppConfig) -> NSEvent.ModifierFlags {
        let str = config.moveToDisplayPrefix ?? "cmd+opt"
        if let mods = HotkeySpec.parseModifiersOnly(str) { return mods }
        Logger.log("invalid moveToDisplayPrefix '\(str)', using cmd+opt")
        return [.command, .option]
    }

    /// Whether HJKL (Vim-style) direction hotkeys should be registered
    /// alongside the arrow keys. Defaults to false.
    static func resolveVimKeys(_ config: AppConfig) -> Bool {
        config.enableVimKeys ?? false
    }
}
