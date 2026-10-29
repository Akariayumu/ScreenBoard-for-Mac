// 键盘窗口：不激活本程序、不成为 key 窗口，点按时当前应用的输入焦点不动。
import AppKit

final class KeyboardPanel: NSPanel {
    private static let autosaveName = "ScreenBoardKeyboard"

    init(injector: KeyInjector) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 310),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 本程序从不激活，默认的“程序失活就隐藏”会让面板一直看不见
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // 风险 7：不用半透明模糊，背景由视图画成不透明圆角
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 560, height: 220)
        contentView = KeyboardView(injector: injector)
        if !setFrameUsingName(Self.autosaveName) {
            placeAtBottomCenter()
        }
        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        orderFrontRegardless()
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { show() }
    }

    private func placeAtBottomCenter() {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 8))
    }
}
