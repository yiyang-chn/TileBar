# TileBar

[中文](README.zh-CN.md)

A tiny macOS menu bar utility that tiles every visible app window across your displays with one hotkey. Layout is a Squarified Treemap weighted by app category; smart toggle to undo, configurable global hotkeys, and per-display window moves. UI auto-localizes to 中文 or English based on system language.

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

## Packaging for distribution

To bundle the Release `.app` into a styled DMG you can hand to a friend:

```bash
brew install create-dmg     # one-time
scripts/package.sh          # → dist/TileBar-<version>.dmg
```

Output is roughly 800KB. The DMG is self-signed (same `TileBarLocal`
identity as the app), **not Apple-notarized** — recipients will see
"developer cannot be verified" on first launch and need to follow the
**First launch** dance below. For zero-warning installs you'd need an
Apple Developer ID + `xcrun notarytool`, which this repo does not set up.

Re-generate the DMG background image only when redesigning it:

```bash
swift scripts/make-dmg-background.swift > scripts/dmg-background.png
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

The icon flips between an outline grid (idle) and a filled grid (busy) while a tile or move is in progress, so you can see your press was received even when the AX work briefly blocks the runloop.

- **Left or right click**: drop-down menu:
  - **Tile Now**: smart toggle. Layout ≈ last tile result → undo to the pre-tile state. Layout ≠ last result → tile fresh.
  - **Move Focused Window to Display N**: shown only with multiple displays, one entry per display (up to 9).
  - **Move Focused Window {Left / Right / Up / Down}**: only entries whose direction has a neighbouring display in your current arrangement are shown.
  - **Settings…**: tile hotkey, move-window modifier prefix, Vim-keys toggle — all in one panel.
  - **Quit TileBar**.

For "tile / undo" without going through the menu, just use the global hotkey (default ⌘⌥T).

### Global hotkeys

| Default | Action |
|---|---|
| **⌘⌥T** | Tile ↔ undo (toggle) |
| **⌘⌥1** | Send focused window to display 1 (move + auto-retile) |
| **⌘⌥2** | Display 2 |
| **⌘⌥N** | Display N (up to 9, dynamically registered to match the actual display count) |
| **⌘⌥→** | Send focused window to the display physically to the right |
| **⌘⌥←** | …to the left |
| **⌘⌥↑** | …above |
| **⌘⌥↓** | …below |
| **⌘⌥H/J/K/L** | Same four directions, Vim-style — opt-in (off by default) |

Single-display setups skip the "send to display" hotkey block (digits and arrows alike) so `⌘⌥1` `⌘⌥←` etc. stay available to your browser. Hotkeys re-register automatically when displays are plugged or unplugged.

**Move-to-display semantics**: it's an atomic *move + auto-retile*. Once the window lands on the destination display, both source and destination get re-squarified. The smart toggle's `pre` snapshot points at the layout *before* the move, so a follow-up ⌘⌥T undoes the entire compound operation in one shot.

### Multi-display

Each display is squarified independently. A window is assigned to the display covering the largest portion of it (a window straddling two screens goes to the one with more area).

The directional move hotkeys (⌘⌥←/→/↑/↓) follow the **physical arrangement** you set up in System Settings → Displays: the destination is the screen directly in that direction with overlap on the perpendicular axis. No display in that direction → no-op. Pressing → on the rightmost screen does **not** wrap around — that's by design; cycling can be done via the digit hotkeys.

Cross-display moves use equiproportional remapping into the target's visibleFrame: the window keeps its relative position and size proportions from the source display.

Moves are CG-verified (not just AX-trusted, since some apps' AX layers report success while their NSWindow controllers silently snap the window back). If the first AX move is rejected, the move is retried up to 5 times with short delays — Tencent WeChat / QQ in particular tend to accept the second or third attempt. A private `CGSMoveWindow` SPI is used as a final fallback.

### Changing hotkeys

Two ways:

- **GUI**: menu → **Settings…** → click the relevant field → press the new combo → **Save**. Esc cancels the in-progress recording; closing the window via X discards everything except what was already saved.
- **Edit the file**: edit `~/.tilebar.json` and relaunch TileBar.

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

`moveToDisplayPrefix` format: modifier-only, at least one of `cmd` / `opt` / `ctrl`. The combined main key is fixed (digits 1-N for direct targeting, ←/→/↑/↓ for spatial directions) — only the prefix is configurable.

`enableVimKeys` (boolean, defaults to `false`): when true, also registers `prefix + h/j/k/l` as Vim-style aliases for the same four directions (h=left, j=down, k=up, l=right). Toggle it via the checkbox in **Settings…** and click **Save**.

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
