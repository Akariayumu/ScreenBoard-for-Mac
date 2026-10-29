// 键盘窗口：不激活本程序、不成为 key 窗口，点按时当前应用的输入焦点不动。
// 位置和大小跟设置走：停靠时铺满屏幕底部；浮动时可拖动，分体布局默认几乎占满屏幕宽度。
import AppKit

final class KeyboardPanel: NSPanel {
    private static let autosaveName = "ScreenBoardKeyboard"

    private let keyboardView: KeyboardView
    /// 上次按设置算窗口大小时的布局；布局没变（例如只换了外观）就不动用户手动调过的大小
    private var applied: (split: Bool, docked: Bool, size: Settings.Size)?

    init(injector: KeyInjector) {
        keyboardView = KeyboardView(injector: injector)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 310),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 本程序从不激活，默认的“程序失活就隐藏”会让面板一直看不见
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // 风险 7：不用半透明模糊，背景由视图画成不透明圆角；分体时中间完全透明，点按会穿透
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 560, height: 220)
        contentView = keyboardView

        let settings = Settings.shared
        let restored = setFrameUsingName(Self.autosaveName)
        setFrameAutosaveName(Self.autosaveName)
        // 浮动时沿用上次的位置和大小；停靠或第一次运行按设置算
        if restored && !settings.docked {
            applied = (settings.split, settings.docked, settings.size)
        }
        applySettings()
        settings.onChange = { [weak self] in self?.applySettings() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { show() }
    }

    private func applySettings() {
        let settings = Settings.shared
        appearance = settings.theme.appearance
        let current = (split: settings.split, docked: settings.docked, size: settings.size)
        if let last = applied, last == current, !settings.docked {
            keyboardView.settingsChanged()
            return
        }
        guard let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }

        let rowHeight = settings.size.rowHeight
        let height = KeyboardView.preferredHeight(rowHeight: rowHeight)
        let target: NSRect
        if settings.docked {
            target = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        } else {
            let width = settings.split ? (visible.width * 0.96).rounded() : KeyboardView.standardWidth(rowHeight: rowHeight)
            // 刚取消停靠或第一次运行：放到底部居中；否则以当前位置为准，不超出屏幕
            let fresh = applied == nil || applied?.docked == true
            let midX = fresh ? visible.midX : frame.midX
            let minY = fresh ? visible.minY + 8 : frame.minY
            target = NSRect(x: min(max(midX - width / 2, visible.minX), visible.maxX - width),
                            y: min(max(minY, visible.minY), visible.maxY - height),
                            width: width, height: height)
        }
        applied = current
        setFrame(target, display: true)
        keyboardView.settingsChanged()
    }

    // 分辨率或 Dock 变化时，停靠的键盘重新贴底
    @objc private func screenParametersChanged() {
        if Settings.shared.docked { applySettings() }
    }
}
