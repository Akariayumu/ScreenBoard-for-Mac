// 键位定义：P0 只有一页英文全键盘（含数字行），宽度以“单位”计，每行合计 KeyLayout.rowUnits。
import Carbon.HIToolbox
import CoreGraphics

enum Modifier: CaseIterable {
    case shift, control, option, command

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .shift: return CGKeyCode(kVK_Shift)
        case .control: return CGKeyCode(kVK_Control)
        case .option: return CGKeyCode(kVK_Option)
        case .command: return CGKeyCode(kVK_Command)
        }
    }
}

struct KeyDef {
    enum Action {
        case key(CGKeyCode)
        case modifier(Modifier)
        case capsLock
        case inputSwitch
        case hide
    }

    let label: String
    var shiftLabel: String? = nil
    var width: CGFloat = 1
    let action: Action
    var isLetter = false
    var repeats = false

    /// 字符键（字母、数字、符号）用大字号，功能键用小字号
    var isCharacter: Bool { shiftLabel != nil }

    func label(shifted: Bool) -> String {
        shifted ? (shiftLabel ?? label) : label
    }
}

private func letter(_ l: String, _ code: Int) -> KeyDef {
    KeyDef(label: l, shiftLabel: l.uppercased(), action: .key(CGKeyCode(code)), isLetter: true)
}

private func symbol(_ l: String, _ shifted: String, _ code: Int) -> KeyDef {
    KeyDef(label: l, shiftLabel: shifted, action: .key(CGKeyCode(code)))
}

private func function(_ l: String, _ code: Int, width: CGFloat = 1, repeats: Bool = false) -> KeyDef {
    KeyDef(label: l, width: width, action: .key(CGKeyCode(code)), repeats: repeats)
}

enum KeyLayout {
    static let rowUnits: CGFloat = 15

    static let rows: [[KeyDef]] = [
        [
            symbol("`", "~", kVK_ANSI_Grave),
            symbol("1", "!", kVK_ANSI_1), symbol("2", "@", kVK_ANSI_2), symbol("3", "#", kVK_ANSI_3),
            symbol("4", "$", kVK_ANSI_4), symbol("5", "%", kVK_ANSI_5), symbol("6", "^", kVK_ANSI_6),
            symbol("7", "&", kVK_ANSI_7), symbol("8", "*", kVK_ANSI_8), symbol("9", "(", kVK_ANSI_9),
            symbol("0", ")", kVK_ANSI_0),
            symbol("-", "_", kVK_ANSI_Minus), symbol("=", "+", kVK_ANSI_Equal),
            function("⌫", kVK_Delete, width: 2, repeats: true),
        ],
        [
            function("⇥", kVK_Tab, width: 1.5),
            letter("q", kVK_ANSI_Q), letter("w", kVK_ANSI_W), letter("e", kVK_ANSI_E), letter("r", kVK_ANSI_R),
            letter("t", kVK_ANSI_T), letter("y", kVK_ANSI_Y), letter("u", kVK_ANSI_U), letter("i", kVK_ANSI_I),
            letter("o", kVK_ANSI_O), letter("p", kVK_ANSI_P),
            symbol("[", "{", kVK_ANSI_LeftBracket), symbol("]", "}", kVK_ANSI_RightBracket),
            KeyDef(label: "\\", shiftLabel: "|", width: 1.5, action: .key(CGKeyCode(kVK_ANSI_Backslash))),
        ],
        [
            KeyDef(label: "⇪", width: 1.75, action: .capsLock),
            letter("a", kVK_ANSI_A), letter("s", kVK_ANSI_S), letter("d", kVK_ANSI_D), letter("f", kVK_ANSI_F),
            letter("g", kVK_ANSI_G), letter("h", kVK_ANSI_H), letter("j", kVK_ANSI_J), letter("k", kVK_ANSI_K),
            letter("l", kVK_ANSI_L),
            symbol(";", ":", kVK_ANSI_Semicolon), symbol("'", "\"", kVK_ANSI_Quote),
            function("↩", kVK_Return, width: 2.25),
        ],
        [
            KeyDef(label: "⇧", width: 2.25, action: .modifier(.shift)),
            letter("z", kVK_ANSI_Z), letter("x", kVK_ANSI_X), letter("c", kVK_ANSI_C), letter("v", kVK_ANSI_V),
            letter("b", kVK_ANSI_B), letter("n", kVK_ANSI_N), letter("m", kVK_ANSI_M),
            symbol(",", "<", kVK_ANSI_Comma), symbol(".", ">", kVK_ANSI_Period), symbol("/", "?", kVK_ANSI_Slash),
            KeyDef(label: "⇧", width: 2.75, action: .modifier(.shift)),
        ],
        [
            function("esc", kVK_Escape),
            KeyDef(label: "⌃ ctrl", width: 1.25, action: .modifier(.control)),
            KeyDef(label: "⌥ opt", width: 1.25, action: .modifier(.option)),
            KeyDef(label: "⌘ cmd", width: 1.25, action: .modifier(.command)),
            KeyDef(label: "中/英", width: 1.25, action: .inputSwitch),
            function("", kVK_Space, width: 4),
            function("←", kVK_LeftArrow, repeats: true),
            function("↑", kVK_UpArrow, repeats: true),
            function("↓", kVK_DownArrow, repeats: true),
            function("→", kVK_RightArrow, repeats: true),
            KeyDef(label: "收起", action: .hide),
        ],
    ]
}
