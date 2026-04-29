import Foundation

enum ContentMeasurer {
    // Higher = window gets more screen area. Tuned so a browser or IDE
    // (dense, layout-heavy content) gets ~4× the area of a terminal or
    // music player. Edit this table to taste.
    private static let coefficients: [(prefix: String, k: Double)] = [
        ("com.apple.dt.Xcode",          2.5),
        ("com.jetbrains.",              2.5),
        ("com.microsoft.VSCode",        2.2),
        ("com.google.Chrome",           2.2),
        ("com.apple.Safari",            2.2),
        ("org.mozilla.firefox",         2.2),
        ("com.anthropic.claudefordesktop", 1.0),
        ("com.tinyspeck.slackmacgap",   0.9),
        ("com.hnc.Discord",             0.9),
        ("com.apple.MobileSMS",         0.7),
        ("com.apple.Terminal",          0.6),
        ("com.googlecode.iterm2",       0.6),
        ("com.spotify.client",          0.3),
        ("com.apple.Music",             0.3),
    ]

    /// Pure category-based weight — intentionally does NOT factor in current
    /// window area, otherwise the plan would depend on the leftover state of
    /// prior tilings and successive clicks would yield different layouts.
    static func weight(for w: WindowInfo) -> Double {
        coefficients.first { w.bundleID?.hasPrefix($0.prefix) == true }?.k ?? 1.0
    }
}
