import Foundation

/// Persistent user config at ~/.tilebar.json. Currently just the hotkey, but
/// designed to grow (coefficients, exclude list, etc.).
struct AppConfig: Codable {
    var hotkey: String

    static let `default` = AppConfig(hotkey: HotkeySpec.default.configString())
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
}
