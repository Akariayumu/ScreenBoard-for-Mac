// 用户设置：布局（标准/分体）、停靠/浮动、尺寸、外观、自动弹出。存在 UserDefaults，改动后回调键盘窗口重排。
// 菜单栏和键盘上的齿轮用同一组菜单项。
import AppKit

final class Settings: NSObject {
    static let shared = Settings()

    enum Size: String, CaseIterable {
        case small, medium, large

        var title: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }

        /// 每行高度（含键间距）
        var rowHeight: CGFloat {
            switch self {
            case .small: return 44
            case .medium: return 54
            case .large: return 66
            }
        }
    }

    enum Theme: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    private let defaults = UserDefaults.standard
    /// 设置变化后调用（键盘窗口用来重排）
    var onChange: (() -> Void)?
    /// 锁屏接力开关变化后调用
    var onLockScreenRelayChange: (() -> Void)?
    /// 当前前台的别的应用，用于“在此应用中不自动弹出”
    var frontAppProvider: (() -> NSRunningApplication?)?

    private(set) var split: Bool
    private(set) var docked: Bool
    private(set) var size: Size
    private(set) var theme: Theme
    private(set) var autoShow: Bool
    private(set) var lockScreenKeyboard: Bool
    private(set) var excludedApps: Set<String>

    private override init() {
        split = defaults.bool(forKey: "split")
        docked = defaults.bool(forKey: "docked")
        size = Size(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        autoShow = defaults.object(forKey: "autoShow") as? Bool ?? true
        lockScreenKeyboard = defaults.object(forKey: "lockScreenKeyboard") as? Bool ?? true
        excludedApps = Set(defaults.stringArray(forKey: "excludedApps") ?? [])
        super.init()
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        bundleID.map { excludedApps.contains($0) } ?? false
    }

    func addItems(to menu: NSMenu) {
        add(to: menu, "分体布局", #selector(toggleSplit)).state = split ? .on : .off
        add(to: menu, "停靠在屏幕底部", #selector(toggleDocked)).state = docked ? .on : .off

        let sizeMenu = NSMenu()
        for s in Size.allCases {
            let item = add(to: sizeMenu, s.title, #selector(selectSize(_:)))
            item.representedObject = s.rawValue
            item.state = s == size ? .on : .off
        }
        addSubmenu(sizeMenu, to: menu, "尺寸")

        let themeMenu = NSMenu()
        for t in Theme.allCases {
            let item = add(to: themeMenu, t.title, #selector(selectTheme(_:)))
            item.representedObject = t.rawValue
            item.state = t == theme ? .on : .off
        }
        addSubmenu(themeMenu, to: menu, "外观")

        menu.addItem(.separator())
        add(to: menu, "点输入框时自动弹出", #selector(toggleAutoShow)).state = autoShow ? .on : .off
        if autoShow, let app = frontAppProvider?(), let id = app.bundleIdentifier {
            let item = add(to: menu, "在“\(app.localizedName ?? id)”中不自动弹出", #selector(toggleExcluded(_:)))
            item.representedObject = id
            item.state = excludedApps.contains(id) ? .on : .off
        }
        add(to: menu, "锁屏时自动启用系统辅助键盘", #selector(toggleLockScreenKeyboard)).state = lockScreenKeyboard ? .on : .off
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func toggleSplit() {
        split.toggle()
        defaults.set(split, forKey: "split")
        changed()
    }

    @objc private func toggleDocked() {
        docked.toggle()
        defaults.set(docked, forKey: "docked")
        changed()
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Size(rawValue: raw) else { return }
        size = value
        defaults.set(raw, forKey: "size")
        changed()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Theme(rawValue: raw) else { return }
        theme = value
        defaults.set(raw, forKey: "theme")
        changed()
    }

    @objc private func toggleAutoShow() {
        autoShow.toggle()
        defaults.set(autoShow, forKey: "autoShow")
        changed()
    }

    @objc private func toggleLockScreenKeyboard() {
        lockScreenKeyboard.toggle()
        defaults.set(lockScreenKeyboard, forKey: "lockScreenKeyboard")
        changed()
        onLockScreenRelayChange?()
    }

    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if excludedApps.contains(id) { excludedApps.remove(id) } else { excludedApps.insert(id) }
        defaults.set(Array(excludedApps).sorted(), forKey: "excludedApps")
        changed()
    }

    private func changed() {
        Diagnostics.shared.log("设置：分体=\(split) 停靠=\(docked) 尺寸=\(size.rawValue) 外观=\(theme.rawValue) "
                               + "自动弹出=\(autoShow) 锁屏接力=\(lockScreenKeyboard) 排除=\(excludedApps.sorted())")
        onChange?()
    }
}
