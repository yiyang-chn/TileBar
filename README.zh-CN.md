# TileBar

[English](README.md)

macOS 菜单栏小工具。一个快捷键平铺当前 Space 上所有显示器的可见普通窗口（Squarified Treemap，按 app 类别加权），支持智能 toggle 撤销、可配置全局快捷键、以及把焦点窗口送到指定显示器。界面根据系统语言自动切换中英文。

## 构建

```bash
cd TileBar
xcodebuild -project TileBar.xcodeproj -scheme TileBar -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
```

## 安装

```bash
cp -R build/Build/Products/Release/TileBar.app ~/Applications/
```

## 打包成 DMG 分享

把 Release `.app` 包成带背景图的 DMG，方便发给朋友：

```bash
brew install create-dmg     # 一次性
scripts/package.sh          # → dist/TileBar-<版本号>.dmg
```

DMG 大约 800KB。用的是 `TileBarLocal` 自签证书，**没有过 Apple 公证**——
朋友首次打开还是会看到"无法验证开发者"，要按下面"首次启动"那段解决。
想要零警告安装，得办 Apple Developer 账号 + `xcrun notarytool` 公证，
本仓库不涉及这套流程。

DMG 背景图只在重新设计时再跑：

```bash
swift scripts/make-dmg-background.swift > scripts/dmg-background.png
```

## 首次启动（macOS 15 Sequoia 及以上）

```bash
open ~/Applications/TileBar.app
```

如果系统提示"无法验证开发者"：

1. 点 Done。
2. 进入 **系统设置 → 隐私与安全性**，滚到 Security 段落。
3. 找到 TileBar 一行，点击 **仍要打开**，输入管理员密码确认。

之后正常 `open` 即可启动。

## Accessibility 授权

首次平铺前会弹引导。在 **系统设置 → 隐私与安全性 → 辅助功能** 勾选 TileBar。授权后 1.5 秒内自动检测到，无需重启。

> **重要**：每次重新构建（ad-hoc 签名 cdhash 变了），TCC 都会失效。要么用 `tccutil reset Accessibility local.tilebar` + 重新勾选，要么用稳定的自签名证书（钥匙串助理 → 证书助理 → 创建证书，类型选"代码签名"，再 build 时加 `CODE_SIGN_IDENTITY="<证书名>"`）。

## 使用

### 菜单栏图标

图标在闲置和忙碌之间切换：闲置是镂空的格子，忙碌（正在平铺/移动）是填充的格子——这样即使 AX 调用短暂阻塞了 runloop，你也能看到自己的按键已经被接收。

- **左键或右键单击**：弹出菜单：
  - **立即平铺**：智能 toggle。当前布局 ≈ 上次平铺结果 → 撤销到平铺前；不一样了 → 重新平铺。
  - **把焦点窗口送到显示器 N**：仅在多屏时显示，每个显示器一项（最多 9）。
  - **把焦点窗口送到{左侧/右侧/上方/下方}显示器**：仅显示当前排列中真有邻居的方向。
  - **设置…**：平铺快捷键、移动窗口修饰键、Vim 方向键开关，全在一个面板里。
  - **退出 TileBar**。

不想走菜单的话直接按全局快捷键（默认 ⌘⌥T）即可"平铺/撤销"。

### 全局快捷键

| 默认快捷键 | 行为 |
|---|---|
| **⌘⌥T** | 平铺 ↔ 撤销（toggle） |
| **⌘⌥1** | 把焦点窗口送到显示器 1（移动 + 自动重平铺） |
| **⌘⌥2** | 显示器 2 |
| **⌘⌥N** | 显示器 N（最多 9，按当前实际显示器数量动态注册） |
| **⌘⌥→** | 焦点窗口送到右侧的显示器 |
| **⌘⌥←** | 左侧 |
| **⌘⌥↑** | 上方 |
| **⌘⌥↓** | 下方 |
| **⌘⌥H/J/K/L** | 同样的四方向，Vim 风格——默认关闭，需要在录制器里勾选启用 |

单显示器时不注册"送往显示器"那组快捷键（含数字和方向键），把 `⌘⌥1` `⌘⌥←` 这类键还给浏览器或其他 app。插拔显示器后自动重注册。

**移动到显示器的语义**：是"移动 + 自动重平铺"的原子操作。窗口送到目标屏后，源屏和目标屏都立即重新 squarify。智能 toggle 的 `pre` 快照保留**移动前**的整体布局，所以移动后立刻按 ⌘⌥T 可以一键还原整套操作。

### 布局决策

窗口按**权重降序**喂给 squarify，所以重 app 进入更大、位置更好的槽位——Chrome 占主导，Slack/Claude 在 16:9 普通显示器上整齐地堆在它右边。

**同权重档**内可以拖拽换位：两个同权重的窗口（比如你并排摆好的两个 Chrome）下次平铺会保持你摆的顺序。**跨权重档**则权重永远赢——你没法把 Chrome 拖到 Terminal 的小角落，下次平铺 Chrome 还会回到主槽位。要给某个 app 单独换大小，去 [TileBar/ContentMeasurer.swift](TileBar/ContentMeasurer.swift) 改权重表。

### 多显示器

每个显示器独立 squarify，互不干扰。窗口归属按"最大面积覆盖"判定（横跨两屏的窗口归到面积更大的那一屏）。

方向键移动（⌘⌥←/→/↑/↓）按 **物理排列** 走：目标屏是当前屏正对着那个方向、且垂直轴上有重叠的那一块。这个方向上没邻居 → no-op，不绕回。要在屏与屏之间循环可以用数字键。

跨屏移动的几何：等比缩放到目标显示器的 visibleFrame 内——保持窗口在源屏的相对位置和尺寸比例。

移动的执行用 CG window list 做真实性校验（AX 层有时返回 success 但应用的 NSWindow controller 会偷偷回滚——Tencent WeChat / QQ 这类是典型）。AX 调用第一次不奏效会自动重试 5 次（间隔 80ms），WeChat 通常第二轮就接受；都失败再走私有 `CGSMoveWindow`。一次按键搞定，不需要用户手动连点。

### 改快捷键

两种方式：

- **GUI**：菜单 → **设置…** → 点击对应输入框 → 按下新组合 → **保存**。Esc 取消正在录制的输入；点窗口的 X 关闭会丢弃所有未保存的修改。
- **手改文件**：编辑 `~/.tilebar.json` 后重启 TileBar。

```json
{
  "hotkey": "cmd+opt+t",
  "moveToDisplayPrefix": "cmd+opt"
}
```

`hotkey` 格式：
- 修饰键：`cmd` / `opt`（或 `alt`）/ `ctrl`（或 `control`）/ `shift`
- 主键：单字母 `t`、数字 `1`、方向键 `left` `right` `up` `down`、具名键 `space` `return` `tab` `escape` `delete` `f1`…`f12`、常见标点 `,` `.` `;` `'` `[` `]` `/` `\` `-` `=` <code>`</code>
- 用 `+` 连接，大小写不敏感。
- 至少要有一个 `cmd` / `opt` / `ctrl`（仅 shift 不够强）。

`moveToDisplayPrefix` 格式：仅修饰键，至少一个 `cmd` / `opt` / `ctrl`。组合的主键固定（数字 1-N 直达、←/→/↑/↓ 按物理方向），不可改。

`enableVimKeys`（布尔，默认 `false`）：true 时额外注册 `prefix + h/j/k/l` 作为 Vim 风格方向键别名（h=左、j=下、k=上、l=右）。在 **设置…** 面板里有勾选框可开关，点 **保存** 生效。

写错了不会崩，日志一行 `invalid ...，using default`，仍按默认值工作。

## 调内容权重

每个 app 的初始权重在 [TileBar/ContentMeasurer.swift](TileBar/ContentMeasurer.swift) 的 `coefficients` 表里，按 bundle id 前缀匹配。改完重建即生效。

数字含义：相对权重。Chrome 2.2、Terminal 0.6 意味着 Chrome 大约会拿 Terminal 的 ~3.7 倍面积。未识别的 app 默认 1.0。

## 风险提示

- 只在当前 Space 操作；全屏 Space、其他 Space 上的窗口会被静默跳过。
- 对每个被操作的 app，TileBar 临时把私有属性 `AXEnhancedUserInterface` 设为 `false` 再操作完恢复。这是 Electron 应用（Slack、Discord、Claude desktop、VS Code）能被 AX 强制 resize 的唯一可靠方法，Yabai/Rectangle/Magnet 等所有 macOS 窗口管理器都用同样的 hack。如果某个 app 在平铺过程中表现出闪屏或动画异常，绝大多数情况是这个开关瞬时切换造成的，操作结束后会恢复到 app 原本的设置。
- 极少数应用（如腾讯 QQ）即使加了 EUI workaround 也完全无视 AX setSize。TileBar 仍然能 setPosition + 把溢出的部分 clamp 回屏内，保证它整窗可见；但这种 app 在小屏上和别的窗口同处一屏时**会重叠**——这是几何不可避免，TileBar 没办法解决。

## 排查

```bash
log show --predicate 'subsystem == "local.tilebar"' --last 5m
log stream --predicate 'subsystem == "local.tilebar"'
```
