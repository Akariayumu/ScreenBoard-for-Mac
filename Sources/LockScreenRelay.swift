// 锁屏接力：macOS 锁屏遮罩（WindowServer）会隐藏所有第三方窗口，只有系统签名的 AssistiveControl 辅助功能键盘能显示。
// 平时在桌面上用 ScreenBoard，锁屏瞬间自动打开系统辅助功能键盘供触屏输密码，解锁回桌面瞬间自动关掉。
import AppKit
import CoreGraphics
import Darwin

final class LockScreenRelay: NSObject {
    private static let activeKey = "lockScreenRelayActive"
    private static let savedHideUIKey = "lockScreenRelaySavedHideUI"
    private static let lockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let unlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    private typealias BoolGetterFn = @convention(c) () -> Bool
    private typealias BoolSetterFn = @convention(c) (Bool) -> Void

    private let panel: KeyboardPanel
    private let defaults = UserDefaults.standard
    private let isEnabledFn: BoolGetterFn?
    private let setEnabledFn: BoolSetterFn?
    private let isHideUIFn: BoolGetterFn?
    private let setHideUIFn: BoolSetterFn?
    private var relayActive: Bool

    init(panel: KeyboardPanel) {
        self.panel = panel
        self.relayActive = defaults.bool(forKey: Self.activeKey)

        let path = "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess"
        if let handle = dlopen(path, RTLD_LAZY) {
            isEnabledFn = dlsym(handle, "UAVirtualKeyboardIsEnabled")
                .map { unsafeBitCast($0, to: BoolGetterFn.self) }
            setEnabledFn = dlsym(handle, "UAVirtualKeyboardSetEnabled")
                .map { unsafeBitCast($0, to: BoolSetterFn.self) }
            isHideUIFn = dlsym(handle, "UAVirtualKeyboardHideUIEnabled")
                .map { unsafeBitCast($0, to: BoolGetterFn.self) }
            setHideUIFn = dlsym(handle, "UAVirtualKeyboardSetHideUIEnabled")
                .map { unsafeBitCast($0, to: BoolSetterFn.self) }
        } else {
            isEnabledFn = nil
            setEnabledFn = nil
            isHideUIFn = nil
            setHideUIFn = nil
        }
        super.init()
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: Self.lockedNotification, object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: Self.unlockedNotification, object: nil, suspensionBehavior: .deliverImmediately)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemOrScreenWoke),
                       name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemOrScreenWoke),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        syncWithCurrentState()
    }

    func stop() {
        if !Self.isSessionLocked(), relayActive {
            setSystemKeyboard(false, reason: "程序退出清理")
        }
    }

    func syncWithCurrentState() {
        if Self.isSessionLocked() {
            if Settings.shared.lockScreenKeyboard {
                activateForLock(reason: "状态同步（当前已锁屏）")
            } else if relayActive {
                setSystemKeyboard(false, reason: "设置关闭")
            }
        } else if relayActive {
            setSystemKeyboard(false, reason: "状态同步（当前未锁屏）")
        }
    }

    @objc private func screenLocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.panel.isVisible {
                self.panel.orderOut(nil)
            }
            guard Settings.shared.lockScreenKeyboard else { return }
            self.activateForLock(reason: "收到锁屏通知")
        }
    }

    @objc private func screenUnlocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.relayActive else { return }
            self.setSystemKeyboard(false, reason: "解锁返回桌面")
        }
    }

    @objc private func systemOrScreenWoke() {
        // 唤醒后稍等锁屏状态稳定再复核，防止睡眠边界通知合并或延迟
        for delay in [0.3, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.syncWithCurrentState()
            }
        }
    }

    private func activateForLock(reason: String) {
        guard let isEnabledFn, let setEnabledFn else {
            Diagnostics.shared.log("锁屏接力：未找到 UniversalAccess 接口")
            return
        }
        if !isEnabledFn() {
            // 系统辅助功能键盘默认开启 15 秒无操作淡化至全透明（alpha=0），睡眠期间会提前隐身导致亮屏看不到键盘
            if let isHideUIFn, isHideUIFn() {
                defaults.set(true, forKey: Self.savedHideUIKey)
            }
            setHideUIFn?(false)
            setRelayActive(true)
            setEnabledFn(true)
            Diagnostics.shared.log("锁屏接力：启用系统辅助键盘（\(reason)）")
        } else if relayActive {
            // 已经由本接力开启，幂等保持不自动淡化隐藏
            setHideUIFn?(false)
            setEnabledFn(true)
        } else {
            Diagnostics.shared.log("锁屏接力：系统辅助键盘原本已开，保持不接管")
        }
    }

    private func setSystemKeyboard(_ enabled: Bool, reason: String) {
        guard let setEnabledFn else { return }
        setEnabledFn(enabled)
        if !enabled, defaults.bool(forKey: Self.savedHideUIKey) {
            setHideUIFn?(true)
            defaults.set(false, forKey: Self.savedHideUIKey)
        }
        setRelayActive(enabled)
        Diagnostics.shared.log("锁屏接力：\(enabled ? "启用" : "关闭")系统辅助键盘（\(reason)）")
    }

    private func setRelayActive(_ active: Bool) {
        relayActive = active
        defaults.set(active, forKey: Self.activeKey)
    }

    static func isSessionLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let num = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return num.boolValue
        }
        return false
    }
}
