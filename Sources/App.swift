// 入口：常驻菜单栏（无 Dock 图标），负责显示/隐藏键盘、辅助功能权限和 P0 诊断摘要。
// 编译：scripts/build-app.sh
import AppKit
import ApplicationServices

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: KeyboardPanel!
    private let injector = KeyInjector()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Diagnostics.shared.log("启动 ScreenBoard \(version)，输入源 \(InputSource.currentID())")

        // 未授权时弹系统提示，引导到“隐私与安全性 → 辅助功能”。键值即 kAXTrustedCheckOptionPrompt
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Diagnostics.shared.log("辅助功能权限：\(trusted ? "已授权" : "未授权")")

        panel = KeyboardPanel(injector: injector)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "屏幕键盘")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        panel.show()
    }

    // 每次打开菜单时重建，权限状态和诊断数字都是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(to: menu, panel.isVisible ? "隐藏键盘" : "显示键盘", #selector(toggleKeyboard))
        menu.addItem(.separator())

        if AXIsProcessTrusted() {
            addItem(to: menu, "辅助功能权限：已授权", nil)
        } else {
            addItem(to: menu, "辅助功能权限：未授权（点此打开设置）", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())

        for line in Diagnostics.shared.summaryLines() {
            addItem(to: menu, line, nil)
        }
        addItem(to: menu, "复制诊断摘要", #selector(copySummary))
        addItem(to: menu, "打开日志", #selector(openLog))
        addItem(to: menu, "重置诊断计数", #selector(resetDiagnostics))
        menu.addItem(.separator())
        addItem(to: menu, "退出", #selector(quit))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector?) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleKeyboard() {
        panel.toggle()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.shared.summaryText(), forType: .string)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Diagnostics.shared.logURL)
    }

    @objc private func resetDiagnostics() {
        Diagnostics.shared.reset()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
