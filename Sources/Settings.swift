// 用户设置：布局（标准/分体）、停靠/浮动、尺寸、外观。存在 UserDefaults，改动后回调键盘窗口重排。
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

    private(set) var split: Bool
    private(set) var docked: Bool
    private(set) var size: Size
    private(set) var theme: Theme

    private override init() {
        split = defaults.bool(forKey: "split")
        docked = defaults.bool(forKey: "docked")
        size = Size(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        super.init()
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

    private func changed() {
        Diagnostics.shared.log("设置：分体=\(split) 停靠=\(docked) 尺寸=\(size.rawValue) 外观=\(theme.rawValue)")
        onChange?()
    }
}
