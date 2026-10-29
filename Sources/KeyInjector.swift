// 按键注入：用 CGEvent 往 HID 层发虚拟键码，当前应用和系统输入法看到的就是普通键盘输入。
// 修饰键按 Win11 触摸键盘的方式：点一下只作用于下一个键，双击常锁，再点一下解除。
import AppKit
import Carbon

enum ModState {
    case off, once, locked
}

final class KeyInjector {
    static let doubleTapInterval: TimeInterval = 0.35
    private static let arrowKeys: Set<CGKeyCode> = [
        CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow), CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow),
    ]

    private(set) var capsLock = false
    private var modifiers: [Modifier: ModState] = [:]
    private var lastModifierTap: [Modifier: TimeInterval] = [:]
    private let source = CGEventSource(stateID: .hidSystemState)

    /// 修饰键 / 大写锁定状态变化时回调，用来重绘键盘
    var onStateChange: (() -> Void)?

    func state(of modifier: Modifier) -> ModState {
        modifiers[modifier] ?? .off
    }

    var shiftActive: Bool { state(of: .shift) != .off }

    func toggleModifier(_ modifier: Modifier) {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleTap = now - (lastModifierTap[modifier] ?? 0) < Self.doubleTapInterval
        lastModifierTap[modifier] = now
        switch state(of: modifier) {
        case .off: modifiers[modifier] = .once
        case .once: modifiers[modifier] = isDoubleTap ? .locked : .off
        case .locked: modifiers[modifier] = .off
        }
        onStateChange?()
    }

    func toggleCaps() {
        capsLock.toggle()
        onStateChange?()
    }

    /// 发一次按键（按下 + 抬起），带上当前的修饰键和 adding；“点一下”的修饰键用完即解除。
    /// ignoreStickyShift：符号页的字符键自己决定要不要 ⇧（放在 adding 里），不理会“点一下”的 ⇧。
    /// 返回需要提示给用户的问题（没有权限、安全输入），没有问题返回 nil。
    @discardableResult
    func tap(_ code: CGKeyCode, isLetter: Bool, adding: [Modifier] = [], ignoreStickyShift: Bool = false) -> String? {
        if let problem = permissionProblem() { return problem }
        let sticky = Modifier.allCases.filter { state(of: $0) != .off && !(ignoreStickyShift && $0 == .shift) }
        var active = Modifier.allCases.filter { sticky.contains($0) || adding.contains($0) }
        var extra: CGEventFlags = []
        // 大写锁定和 ⇧ 同时开时，字母是小写，和实体键盘一致
        if capsLock && isLetter {
            if let i = active.firstIndex(of: .shift) { active.remove(at: i) } else { extra.insert(.maskShift) }
        }
        if Self.arrowKeys.contains(code) { extra.formUnion([.maskNumericPad, .maskSecondaryFn]) }
        let warning = secureInputWarning()
        postChord(code, modifiers: active, extraFlags: extra)

        var changed = false
        for m in sticky where state(of: m) == .once {
            modifiers[m] = .off
            changed = true
        }
        if changed { onStateChange?() }
        return warning
    }

    /// 直接输入字符（长按备选里的 é、…、「 等 US 键位打不出的字符），不经过键码，不带修饰键。
    @discardableResult
    func type(_ text: String) -> String? {
        if let problem = permissionProblem() { return problem }
        let warning = secureInputWarning()
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
        return warning
    }

    /// 切换输入法：发系统默认的“选择上一个输入法”快捷键 ⌃空格，不受锁定的修饰键影响。
    @discardableResult
    func switchInputSource() -> String? {
        if let problem = permissionProblem() { return problem }
        postChord(CGKeyCode(kVK_Space), modifiers: [.control], extraFlags: [])
        return nil
    }

    // 按 Apple 文档的顺序发：修饰键逐个按下 → 主键按下/抬起 → 修饰键逆序抬起
    private func postChord(_ code: CGKeyCode, modifiers active: [Modifier], extraFlags: CGEventFlags) {
        var held: CGEventFlags = []
        for m in active {
            held.insert(m.flag)
            post(m.keyCode, down: true, flags: held)
        }
        post(code, down: true, flags: held.union(extraFlags))
        post(code, down: false, flags: held.union(extraFlags))
        for m in active.reversed() {
            held.remove(m.flag)
            post(m.keyCode, down: false, flags: held)
        }
    }

    private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func permissionProblem() -> String? {
        guard !AXIsProcessTrusted() else { return nil }
        Diagnostics.shared.count("无权限时按键")
        return "没有辅助功能权限，按键发不出去：点菜单栏键盘图标去授权"
    }

    // 风险 3：密码框会开启安全输入，合成的按键可能被系统拦截。照常发送，只记录和提示，用来实测。
    private func secureInputWarning() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        Diagnostics.shared.count("安全输入时按键")
        return "安全输入已开启（密码框等），看按键有没有进去"
    }
}

enum InputSource {
    // 即 kTISNotifySelectedKeyboardInputSourceChanged，经分布式通知中心发出
    static let changedNotification = Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")

    static func currentID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "?" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// 键盘布局（ABC 等）的 ID 以 com.apple.keylayout. 开头，其余视为输入法（本机只有简体拼音）
    static var isIME: Bool {
        !currentID().hasPrefix("com.apple.keylayout.")
    }
}
