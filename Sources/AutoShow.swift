// 自动弹出（P2）：在别的应用里点按后，点中的是文本控件、输入焦点也在文本控件上，就弹出键盘；
// 焦点离开文本控件（或切到焦点不在文本控件上的应用）时，收起由自动弹出打开的键盘，手动打开的不收。
// 用 Tab 切焦点、程序自己设焦点都不弹，和 Win11 一样只响应点按。
// 焦点用辅助功能 API 读：点按后查点中的元素和当前焦点决定弹出；AXObserver 监听焦点变化决定收起。
import AppKit
import ApplicationServices

private func focusChangedCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                                  _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AutoShowController>.fromOpaque(refcon).takeUnretainedValue().focusChanged(to: element)
}

final class AutoShowController: NSObject {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private let panel: KeyboardPanel
    private let systemWide = AXUIElementCreateSystemWide()
    /// 当前前台的别的应用（本程序从不在前台），菜单里“在此应用中不自动弹出”用
    private(set) var currentApp: NSRunningApplication?
    private var observer: AXObserver?
    private var shownByAuto = false
    private var hideWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    /// 最近 1 秒内的光标移动（风险 6 诊断：触摸点按是光标直接跳过去，触控板点击前通常有一串移动）
    private var recentMoves: [(time: TimeInterval, dx: Double, dy: Double)] = []
    /// 已试过打开 AXEnhancedUserInterface 的应用
    private var enhancedTried: Set<pid_t> = []

    init(panel: KeyboardPanel) {
        self.panel = panel
        super.init()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { observe(app) }

        // 全局监听只收到别的应用的事件，点键盘本身不会触发
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .mouseMoved]) {
            [weak self] event in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch event.type {
            case .mouseMoved:
                self.recentMoves.removeAll { now - $0.time > 1 }
                self.recentMoves.append((now, event.deltaX, event.deltaY))
            case .leftMouseDown:
                self.recentMoves.removeAll { now - $0.time > 1 }
                Diagnostics.shared.clickSource(event, moves: self.recentMoves.map { (now - $0.time, $0.dx, $0.dy) })
                self.recentMoves.removeAll()
            default:
                guard let point = event.cgEvent?.location else { return }
                // 等焦点落定再查
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.checkAfterClick(at: point) }
            }
        }
    }

    // MARK: 弹出

    private func checkAfterClick(at point: CGPoint) {
        let settings = Settings.shared
        guard settings.autoShow, !panel.isVisible, !LockScreenRelay.isSessionLocked() else { return }
        let app = NSWorkspace.shared.frontmostApplication
        let focused = focusedElement()
        guard clickedEditable(at: point), let focused, Self.isEditable(focused) else {
            // 诊断：Electron 等应用点了输入框却没弹出时，看点中的元素和焦点各是什么
            Diagnostics.shared.log("未弹出：\(app?.bundleIdentifier ?? "?") 点中 \(roleChain(at: point)) 焦点 "
                                   + (focused.map(Self.describe) ?? "无"))
            if focused == nil, let app { tryEnhancedUserInterface(app) }
            return
        }
        if settings.isExcluded(app?.bundleIdentifier) {
            Diagnostics.shared.log("自动弹出：\(app?.bundleIdentifier ?? "?") 已排除")
            return
        }
        hideWork?.cancel()
        panel.show()
        shownByAuto = true
        Diagnostics.shared.log("自动弹出：\(app?.bundleIdentifier ?? "?") \(Self.describe(focused))")
    }

    /// 点中的元素或它往上几层里有文本控件（点在输入框里的文字上时，点中的是里面的静态文本）
    private func clickedEditable(at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return false }
        for _ in 0..<6 {
            if Self.isEditable(element) { return true }
            guard let parent = Self.attribute(element, "AXParent") else { return false }
            element = parent as! AXUIElement
        }
        return false
    }

    /// 有的应用（例如网易云音乐）不支持 AXManualAccessibility，界面里一个元素都读不到。
    /// 部分 Chromium/CEF 内核的应用会响应 AXEnhancedUserInterface（VoiceOver 打开时也设这个），
    /// 但它可能让这个应用的窗口动画变卡，所以只对读不到焦点的非苹果应用试一次
    private func tryEnhancedUserInterface(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        Diagnostics.shared.log("tryEnhanced 进入 \(app.bundleIdentifier ?? "?") pid=\(pid) 已试=\(enhancedTried.contains(pid))")
        guard !(app.bundleIdentifier ?? "").hasPrefix("com.apple."), !enhancedTried.contains(pid) else { return }
        enhancedTried.insert(pid)
        let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                                  "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Diagnostics.shared.log("试打开 AXEnhancedUserInterface：\(app.bundleIdentifier ?? "\(pid)") 结果 \(result.rawValue)")
    }

    private func roleChain(at point: CGPoint) -> String {
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard result == .success, var element = hit else { return "失败(\(result.rawValue))" }
        var roles: [String] = []
        for _ in 0..<6 {
            roles.append(Self.describe(element))
            guard let parent = Self.attribute(element, "AXParent") else { break }
            element = parent as! AXUIElement
        }
        return roles.joined(separator: " < ")
    }

    // MARK: 收起

    fileprivate func focusChanged(to element: AXUIElement) {
        if Self.isEditable(element) {
            hideWork?.cancel()
        } else {
            scheduleHide()
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        observe(app)
        if let focused = focusedElement(), Self.isEditable(focused) {
            hideWork?.cancel()
        } else {
            scheduleHide()
        }
    }

    /// 稍等再收：在两个输入框之间切换时，焦点会短暂离开文本控件
    private func scheduleHide() {
        guard shownByAuto, panel.isVisible else {
            shownByAuto = false
            return
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownByAuto else { return }
            if let focused = self.focusedElement(), Self.isEditable(focused) { return }
            self.panel.orderOut(nil)
            self.shownByAuto = false
            Diagnostics.shared.log("自动收起")
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: 辅助功能

    private func observe(_ app: NSRunningApplication) {
        stopObserving()
        currentApp = app
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        // Electron/Chromium 默认不把网页内容交给辅助功能 API，设了这个才能读到网页里的输入框；别的应用会忽略
        let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if !(app.bundleIdentifier ?? "").hasPrefix("com.apple.") {
            Diagnostics.shared.log("前台：\(app.bundleIdentifier ?? "\(pid)") AXManualAccessibility=\(manual.rawValue)")
        }

        var created: AXObserver?
        guard AXObserverCreate(pid, focusChangedCallback, &created) == .success, let created else {
            Diagnostics.shared.log("自动弹出：无法监听 \(app.bundleIdentifier ?? "\(pid)")")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(created, element, "AXFocusedUIElementChanged" as CFString, refcon)
        if result != .success {
            Diagnostics.shared.log("自动弹出：监听 \(app.bundleIdentifier ?? "\(pid)") 焦点失败（\(result.rawValue)）")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
    }

    private func focusedElement() -> AXUIElement? {
        Self.attribute(systemWide, "AXFocusedUIElement").map { $0 as! AXUIElement }
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        if let role = attribute(element, "AXRole") as? String, textRoles.contains(role) { return true }
        // 网页里的 contenteditable：WebKit 会给可编辑区域里的元素标上可编辑祖先
        return attribute(element, "AXEditableAncestor") != nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = attribute(element, "AXRole") as? String ?? "?"
        let subrole = attribute(element, "AXSubrole") as? String
        return subrole.map { "\(role)/\($0)" } ?? role
    }
}

/// 调试用：ScreenBoard --probe <bundleID>。对指定应用打开 AXManualAccessibility 和 AXEnhancedUserInterface，
/// 前后各导出一次界面元素树到日志，然后退出。只读界面结构，不发按键。
enum AccessibilityProbe {
    static func run(bundleID: String) {
        let log = Diagnostics.shared.log
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            log("probe：\(bundleID) 没在运行")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        log("probe 开始 \(bundleID) pid=\(app.processIdentifier) 辅助功能=\(AXIsProcessTrusted())")
        dump(element, label: "设置前")
        let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        log("probe AXManualAccessibility=\(manual.rawValue) AXEnhancedUserInterface=\(enhanced.rawValue)")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        dump(element, label: "设置后 3 秒")
    }

    private static func dump(_ app: AXUIElement, label: String) {
        var lines: [String] = []
        let focused = attribute(app, "AXFocusedUIElement").map { describe($0 as! AXUIElement) } ?? "无"
        lines.append("焦点 \(focused)")
        let windows = attribute(app, "AXWindows") as? [AXUIElement] ?? []
        var budget = 120
        for window in windows.prefix(2) {
            walk(window, depth: 0, lines: &lines, budget: &budget)
        }
        Diagnostics.shared.log("probe \(label)：\n  " + lines.joined(separator: "\n  "))
    }

    private static func walk(_ element: AXUIElement, depth: Int, lines: inout [String], budget: inout Int) {
        guard budget > 0, depth <= 12 else { return }
        budget -= 1
        lines.append(String(repeating: "  ", count: depth) + describe(element))
        for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
            walk(child, depth: depth + 1, lines: &lines, budget: &budget)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func describe(_ element: AXUIElement) -> String {
        let role = attribute(element, "AXRole") as? String ?? "?"
        let subrole = attribute(element, "AXSubrole") as? String
        let title = (attribute(element, "AXTitle") as? String) ?? (attribute(element, "AXDescription") as? String) ?? ""
        return (subrole.map { "\(role)/\($0)" } ?? role) + (title.isEmpty ? "" : " “\(title.prefix(20))”")
    }
}
