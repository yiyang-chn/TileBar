# TileBar

[中文](README.zh-CN.md)

A tiny macOS menu bar utility that tiles every visible app window across your displays in one click. Layout is a Squarified Treemap weighted by app category; smart toggle to undo, configurable global hotkeys, and per-display window moves.

## Build

```bash
cd TileBar
xcodebuild -project TileBar.xcodeproj -scheme TileBar -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
```

## Install

```bash
cp -R build/Build/Products/Release/TileBar.app ~/Applications/
```

## First launch (macOS 15 Sequoia and later)

```bash
open ~/Applications/TileBar.app
```

If macOS shows "developer cannot be verified":

1. Click Done.
2. Open **System Settings → Privacy & Security**, scroll to the Security section.
3. Find the TileBar row and click **Open Anyway**, confirm with your admin password.

After that `open` works normally.

## Accessibility permission

TileBar prompts the first time you tile. Tick TileBar in **System Settings → Privacy & Security → Accessibility**. The app polls every 1.5 s and picks up the grant automatically — no restart needed.

> **Heads up**: every rebuild produces a new ad-hoc cdhash, which invalidates the TCC entry. Either run `tccutil reset Accessibility local.tilebar` and re-tick, or use a stable self-signed certificate (Keychain Access → Certificate Assistant → Create a Certificate, type "Code Signing", then build with `CODE_SIGN_IDENTITY="<cert name>"`).

## Usage

### Menu bar icon

- **Left click**: smart toggle.
  - Layout ≈ last tile result (you haven't touched anything) → undo to the pre-tile state.
  - Layout ≠ last result (window dragged, opened, or closed) → tile fresh.
- **Right click / Control click**: drop-down menu:
  - **Tile now**: forces a fresh tile, ignoring toggle state.
  - **Send focused window to display N**: appears only with multiple displays, one entry per display.
  - **Send focused window to previous/next display**: cyclic.
  - **Set tile hotkey…**: record a new combo for the toggle.
  - **Set move-window modifier…**: record the modifier prefix that combines with digits / arrows.
  - **Reload config**: re-reads `~/.tilebar.json`.
  - **Quit TileBar**.

### Global hotkeys

| Default | Action |
|---|---|
| **⌘⌥T** | Tile ↔ undo (toggle) |
| **⌘⌥1** | Send focused window to display 1 (move + auto-retile) |
| **⌘⌥2** | Display 2 |
| **⌘⌥N** | Display N (up to 9, dynamically registered to match the actual display count) |
| **⌘⌥→** | Send focused window to the next display (cyclic) |
| **⌘⌥←** | Previous display (cyclic) |

Single-display setups skip the "send to display" hotkey block (digits and arrows alike) so `⌘⌥1` `⌘⌥←` etc. stay available to your browser. Hotkeys re-register automatically when displays are plugged or unplugged.

**Move-to-display semantics**: it's an atomic *move + auto-retile*. Once the window lands on the destination display, both source and destination get re-squarified. The smart toggle's `pre` snapshot points at the layout *before* the move, so a follow-up ⌘⌥T undoes the entire compound operation in one shot.

### Multi-display

Each display is squarified independently. A window is assigned to the display covering the largest portion of it (a window straddling two screens goes to the one with more area).

Cross-display moves use equiproportional remapping into the target's visibleFrame: the window keeps its relative position and size proportions from the source display.

### Changing hotkeys

Two ways:

- **GUI**: right-click menu → Set tile hotkey / Set move-window modifier → press the new combo → Save.
- **Edit the file**: edit `~/.tilebar.json`, then right-click menu → Reload config (or restart the app).

```json
{
  "hotkey": "cmd+opt+t",
  "moveToDisplayPrefix": "cmd+opt"
}
```

`hotkey` format:
- Modifiers: `cmd` / `opt` (or `alt`) / `ctrl` (or `control`) / `shift`
- Main key: single letter `t`, digit `1`, arrow `left` `right` `up` `down`, named key `space` `return` `tab` `escape` `delete` `f1`…`f12`, common punctuation `,` `.` `;` `'` `[` `]` `/` `\` `-` `=` <code>`</code>
- Joined by `+`, case-insensitive.
- Must include at least one of `cmd` / `opt` / `ctrl` (shift alone isn't strong enough).

`moveToDisplayPrefix` format: modifier-only, at least one of `cmd` / `opt` / `ctrl`. The combined main key is fixed (digits 1-N for direct targeting, ←/→ for cyclic prev/next) — only the prefix is configurable.

Malformed values don't crash; the log records `invalid ..., using default` and the app falls back to the default.

## Tweaking content weights

The per-app weights live in the `coefficients` table at [TileBar/ContentMeasurer.swift](TileBar/ContentMeasurer.swift), matched by bundle id prefix. Edit, rebuild, done.

What the numbers mean: relative area weight. Chrome 2.2 and Terminal 0.6 means Chrome will get roughly 3.7× the area of Terminal. Apps not in the table default to 1.0.

## Caveats

- Operates on the current Space only. Full-screen Spaces and windows on other Spaces are skipped silently.
- For every app it manipulates, TileBar temporarily flips the private `AXEnhancedUserInterface` attribute to `false` and restores it after. This is the only reliable way to make Electron apps (Slack, Discord, Claude desktop, VS Code) actually obey AX-driven resize — same trick used by Yabai, Rectangle, Magnet, and every other macOS window manager. If you ever notice a brief animation glitch in one of those apps during tiling, that's the toggle.
- A handful of apps (notably Tencent QQ) ignore AX setSize entirely even with that workaround. TileBar still places them via setPosition and clamps any overflow back inside the display, so they stay fully visible — but two such apps on a small external display may end up overlapping. That's geometric; nothing TileBar can do.

## Troubleshooting

```bash
log show --predicate 'subsystem == "local.tilebar"' --last 5m
log stream --predicate 'subsystem == "local.tilebar"'
```
