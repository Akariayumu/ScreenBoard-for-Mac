# 仿 Win11 屏幕键盘：难度评估与技术选型（预研究）

2026-10-29。目标：桌面日常输入（不含锁屏），触摸屏点按为主，体验接近 Win11 触摸键盘。

## 本机条件（已核实）

- macOS 15.8.1；没有 Xcode，只有 CommandLineTools：Swift 6.1.2、SDK 15.5，可以直接用 `swiftc` 编译 .app。
- 输入法：ABC + 系统简体拼音（`com.apple.inputmethod.SCIM.ITABC`）。
- 触摸屏走 VoodooI2C：手指点击/滑动/缩放、笔都正常。**系统没有给应用的触摸屏多点 API**，手指点按到应用里就是鼠标点击。

## 要做的几件事和难度

| 能力 | 做法 | 难度 |
|---|---|---|
| 浮动键盘窗口，点按不抢焦点 | `NSPanel` + `.nonactivatingPanel`，`canBecomeKey = false`，按键视图 `acceptsFirstMouse = true`；层级 `.floating`，`collectionBehavior` 加 `.canJoinAllSpaces` `.fullScreenAuxiliary`（全屏应用里也能用） | 低 |
| 把按键送进当前应用 | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` + `post(tap: .cghidEventTap)`，发虚拟键码；需要“辅助功能”权限 | 低 |
| 中文输入 | 发虚拟键码，系统拼音照常工作；候选窗是系统的，出现在光标旁，手指点候选即可 | 低 |
| Shift/Ctrl/Cmd 等修饰键 | 触摸屏不能同时按两个键 → 做成 Win11 那样的“点一下锁一次、双击常锁” | 低 |
| 外观：圆角键、深浅色、半透明 | 自绘 `NSView`/`CALayer`；半透明用 `NSVisualEffectView` | 低–中 |
| 数字/符号页、长按出备选字符（é、…）、按键音、尺寸/停靠/浮动切换 | 纯界面逻辑 | 中 |
| 点到输入框自动弹出、离开自动收起 | 辅助功能 API：跟踪前台应用，`AXObserver` 监听 `kAXFocusedUIElementChangedNotification`，按角色判断（`AXTextField`/`AXTextArea`/`AXComboBox`/可编辑 web 区域） | 中–高 |
| 键盘里自带候选栏（Win11 那样候选在键盘上方） | 读不到系统拼音的候选。要自己做输入法：InputMethodKit + librime 拼音引擎，键盘和输入法进程通信 | 高 |
| 表情面板 | 自己做表情网格，用 `CGEventKeyboardSetUnicodeString` 直接送字符；或一个键打开系统字符检视器（Ctrl+Cmd+空格） | 中 |
| 剪贴板历史 | 轮询 `NSPasteboard.changeCount` 记录，点按回贴 | 中 |
| 锁屏 | 第三方应用画不到锁屏上，做不了（用系统辅助功能键盘） | 不做 |

## 技术选型

**推荐：Swift + AppKit，原生单应用。**
- 键盘窗口、按键绘制、事件注入、辅助功能 API 都是 AppKit/CoreGraphics 的原生能力，不需要桥接。
- 设置窗口可用 SwiftUI（`NSHostingView` 嵌进 AppKit）；键盘本体用 AppKit 自绘，按下反馈和“首次点击”处理更可控。
- 在 Mac 上用 `swiftc` + 打包脚本构建，和 Wallpaper4Mac 的 `scripts/build-app.sh` 同一套路。
- 开机自启用 `SMAppService.mainApp`（应用内开关，在“登录项”里可见）。

不选的：
- **Electron / Tauri**：体积大；“不抢焦点的面板”在 Electron 里只部分支持；按键注入和辅助功能 API 还得写原生模块，等于两套技术。
- **纯 SwiftUI**：不抢焦点的面板和 first-mouse 仍要落回 AppKit，按键多时按下态反馈不如自绘稳定。
- **Python/PyObjC**：只适合验证原型。

中文候选栏（第 3 阶段才考虑）：
- 方案 A（默认）：继续用系统拼音，候选在光标旁的系统候选窗里。零成本，体验和 Win11 不同但能用。
- 方案 B：基于 librime 自做 InputMethodKit 输入法，候选通过进程间通信显示在键盘上。librime 本身是 BSD-3；词库（如 rime-ice、朙月拼音）许可证各不相同，做之前要逐个确认。工作量最大。

## 风险和需要先验证的点

1. **触摸屏长按**：VoodooI2C 触摸屏驱动可能把长按转成右键或拖动，会影响“长按出备选字符”。原型阶段实测，不行就改成上滑出备选。
2. **点按延迟**：手指点按到鼠标事件的延迟，决定连续打字是否跟手。原型阶段测。
3. **密码框**：密码输入框会打开系统的安全输入模式，合成的按键能不能送进去要实测。
4. **辅助功能权限反复失效**：临时签名的应用每次重新编译，系统会认为是新程序，要重新授权。用一个固定的自签名证书签名可以避免，需要你在“钥匙串访问”里建一次证书。
5. **自动弹出的覆盖面**：原生应用的输入框容易识别；Electron/Chrome 系应用（包括 Claude 桌面端）默认不把网页里的焦点暴露给辅助功能 API，要对它们设置 `AXManualAccessibility`，可能有兼容性和性能影响。识别不到的应用只能手动呼出。
6. **区分触摸和触控板**：Win11 只在用手指点输入框时自动弹出。这里要从事件来源区分触摸屏和触控板，未验证；做不到就改成“任何方式聚焦输入框都弹出”并提供按应用的黑名单。
7. **图形稳定性**：本机今天出现过 WindowServer GPU 卡死。半透明模糊会增加 WindowServer 合成负担，默认先用不透明背景，模糊作为可选项。

## 分阶段和工作量（粗估）

| 阶段 | 内容 | 粗估 |
|---|---|---|
| P0 原型 | 不抢焦点面板 + 英文全键盘 + 键码注入 + 修饰键锁定 + 菜单栏开关；验证风险 1–4 | 1–2 天 |
| P1 日用版 | Win11 外观、深浅色、数字/符号页、长按备选、按键音、尺寸/停靠/浮动、记住位置、开机自启 | 3–5 天 |
| P2 自动弹出 | 辅助功能焦点跟踪、应用黑名单、Electron 兼容 | 3–5 天，效果取决于应用覆盖 |
| P3 增强 | 表情面板、剪贴板历史、空格键滑动移光标、分体布局 | 3–5 天 |
| P4 自带候选栏 | librime + InputMethodKit 输入法 | 1–2 周，风险最高 |

建议先做 P0，把风险 1–4 在实机上验证掉，再决定 P1 之后的范围。
