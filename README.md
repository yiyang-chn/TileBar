# TileBar

macOS 菜单栏小工具。一次平铺当前 Space + 主显示器上所有可见普通窗口（Squarified Treemap，按 app 类别加权），并支持智能 toggle 撤销与可配置全局快捷键。

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

> **重要**：每次重新构建（ad-hoc 签名 cdhash 变了），TCC 都会失效。要么用 `tccutil reset Accessibility local.tilebar` + 重新勾选，要么用稳定的自签名证书（钥匙串助理生成本地代码签名证书后，build 时加 `CODE_SIGN_IDENTITY="<证书名>"`）。

## 使用

### 菜单栏图标

- **左键单击**：智能 toggle。
  - 当前布局 ≈ 上次平铺结果（你没动过窗口）→ 撤销到平铺前的状态。
  - 当前布局 ≠ 上次结果（拖动过、新开/关了窗口）→ 重新平铺。
- **右键单击 / Control 单击**：弹出菜单：
  - **立即平铺**：忽略 toggle 状态，直接做一次新的平铺。
  - **设置快捷键…**：打开录制窗口，按下你想要的组合键即可保存。
  - **重新加载配置**：重新读取 `~/.tilebar.json`。
  - **退出 TileBar**。

### 全局快捷键

默认 **⌘⌥T**。任何前台 app 下按一下就触发智能 toggle，等价于左键点菜单栏图标。

### 改快捷键

两种方式：

- **GUI**：右键菜单 → 设置快捷键 → 按下新组合 → 保存。
- **手改文件**：编辑 `~/.tilebar.json`，然后右键菜单 → 重新加载配置（或重启 app）。

```json
{ "hotkey": "cmd+opt+t" }
```

格式：
- 修饰键：`cmd` / `opt`（或 `alt`）/ `ctrl`（或 `control`）/ `shift`
- 主键：单字母 `t`、数字 `1`、具名键 `space` `return` `tab` `escape` `delete` `f1`…`f12`、常见标点 `,` `.` `;` `'` `[` `]` `/` `\` `-` `=` <code>`</code>
- 用 `+` 连接，大小写不敏感。
- 至少要有一个 `cmd` / `opt` / `ctrl`（仅 shift 不够强）。

写错了不会崩，日志一行 `invalid hotkey '...'，using default`，仍按默认或上一次的快捷键工作。

## 调内容权重

每个 app 的初始权重在 [TileBar/ContentMeasurer.swift](TileBar/ContentMeasurer.swift) 的 `coefficients` 表里，按 bundle id 前缀匹配。改完重建即生效。

数字含义：相对权重。Chrome 2.2、Terminal 0.6 意味着 Chrome 大约会拿 Terminal 的 ~3.7 倍面积。未识别的 app 默认 1.0。

## 风险提示

- 只在主显示器、当前 Space 操作；多显示器、跨 Space、全屏窗口会被静默跳过。
- 对每个被操作的 app，TileBar 临时把私有属性 `AXEnhancedUserInterface` 设为 `false` 再操作完恢复。这是 Electron 应用（Slack、Discord、Claude desktop、VS Code）能被 AX 强制 resize 的唯一可靠方法，Yabai/Rectangle/Magnet 等所有 macOS 窗口管理器都用同样的 hack。如果某个 app 在平铺过程中表现出闪屏或动画异常，绝大多数情况是这个开关瞬时切换造成的，操作结束后会恢复到 app 原本的设置。

## 排查

```bash
log show --predicate 'subsystem == "local.tilebar"' --last 5m
log stream --predicate 'subsystem == "local.tilebar"'
```
