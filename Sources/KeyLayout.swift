// 键位定义：字母页和符号页（&123），宽度以“单位”计，每行合计 KeyLayout.rowUnits。
// 符号页只放 US 键位上打得出的 ASCII 字符，全部走键码，系统拼音照常把 , . ? 等转成中文标点。
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

enum KeyPage {
    case letters, symbols
}

struct KeyDef {
    enum Action {
        case key(CGKeyCode)
        case modifier(Modifier)
        case capsLock
        case inputSwitch
        case page(KeyPage)
        case hide
    }

    let label: String
    var shiftLabel: String? = nil
    var width: CGFloat = 1
    let action: Action
    var isLetter = false
    /// 字符键（字母、数字、符号）用大字号，功能键用小字号
    var isCharacter = false
    var repeats = false
    /// 长按时加 ⌥ 发出：⌫ 删一个词，←/→ 按词移动
    var optionOnLongPress = false
    /// 固定带上的修饰键：符号页的上档符号带 ⇧，编辑键带 ⌘
    var fixedModifiers: [Modifier] = []
    /// 长按弹出的备选字符（不含本键字符）
    var alternates: [String] = []

    /// 符号页的字符键自己决定要不要 ⇧，不受“点一下”的 ⇧ 影响
    var ignoresStickyShift: Bool { isCharacter && shiftLabel == nil }

    func label(shifted: Bool) -> String {
        shifted ? (shiftLabel ?? label) : label
    }
}

// US 键位上每个数字/符号对应的键码，以及是否要按 ⇧
private let usKeys: [String: (code: Int, shift: Bool)] = [
    "`": (kVK_ANSI_Grave, false), "~": (kVK_ANSI_Grave, true),
    "1": (kVK_ANSI_1, false), "!": (kVK_ANSI_1, true),
    "2": (kVK_ANSI_2, false), "@": (kVK_ANSI_2, true),
    "3": (kVK_ANSI_3, false), "#": (kVK_ANSI_3, true),
    "4": (kVK_ANSI_4, false), "$": (kVK_ANSI_4, true),
    "5": (kVK_ANSI_5, false), "%": (kVK_ANSI_5, true),
    "6": (kVK_ANSI_6, false), "^": (kVK_ANSI_6, true),
    "7": (kVK_ANSI_7, false), "&": (kVK_ANSI_7, true),
    "8": (kVK_ANSI_8, false), "*": (kVK_ANSI_8, true),
    "9": (kVK_ANSI_9, false), "(": (kVK_ANSI_9, true),
    "0": (kVK_ANSI_0, false), ")": (kVK_ANSI_0, true),
    "-": (kVK_ANSI_Minus, false), "_": (kVK_ANSI_Minus, true),
    "=": (kVK_ANSI_Equal, false), "+": (kVK_ANSI_Equal, true),
    "[": (kVK_ANSI_LeftBracket, false), "{": (kVK_ANSI_LeftBracket, true),
    "]": (kVK_ANSI_RightBracket, false), "}": (kVK_ANSI_RightBracket, true),
    "\\": (kVK_ANSI_Backslash, false), "|": (kVK_ANSI_Backslash, true),
    ";": (kVK_ANSI_Semicolon, false), ":": (kVK_ANSI_Semicolon, true),
    "'": (kVK_ANSI_Quote, false), "\"": (kVK_ANSI_Quote, true),
    ",": (kVK_ANSI_Comma, false), "<": (kVK_ANSI_Comma, true),
    ".": (kVK_ANSI_Period, false), ">": (kVK_ANSI_Period, true),
    "/": (kVK_ANSI_Slash, false), "?": (kVK_ANSI_Slash, true),
]

private func chars(_ s: String) -> [String] {
    s.map(String.init)
}

private func letter(_ l: String, _ code: Int, _ alternates: String = "") -> KeyDef {
    KeyDef(label: l, shiftLabel: l.uppercased(), action: .key(CGKeyCode(code)), isLetter: true, isCharacter: true,
           alternates: chars(alternates))
}

/// 字母页的数字/符号键：带上档字符
private func symbol(_ l: String, _ shifted: String, _ alternates: String = "", width: CGFloat = 1) -> KeyDef {
    KeyDef(label: l, shiftLabel: shifted, width: width, action: .key(CGKeyCode(usKeys[l]!.code)), isCharacter: true,
           alternates: chars(alternates))
}

/// 符号页的字符键：一个键一个字符，需要 ⇧ 的自动带上
private func char(_ c: String, _ alternates: String = "", width: CGFloat = 1) -> KeyDef {
    let key = usKeys[c]!
    return KeyDef(label: c, width: width, action: .key(CGKeyCode(key.code)), isCharacter: true,
                  fixedModifiers: key.shift ? [.shift] : [], alternates: chars(alternates))
}

private func function(_ l: String, _ code: Int, width: CGFloat = 1, repeats: Bool = false,
                      optionOnLongPress: Bool = false) -> KeyDef {
    KeyDef(label: l, width: width, action: .key(CGKeyCode(code)), repeats: repeats,
           optionOnLongPress: optionOnLongPress)
}

/// 编辑快捷键：⌘ + 字母
private func edit(_ l: String, _ code: Int) -> KeyDef {
    KeyDef(label: l, width: 1.6, action: .key(CGKeyCode(code)), fixedModifiers: [.command])
}

private let backspace = function("⌫", kVK_Delete, width: 2, repeats: true, optionOnLongPress: true)

private func bottomRow(pageKey: KeyDef) -> [KeyDef] {
    [
        pageKey,
        KeyDef(label: "⌃ ctrl", width: 1.25, action: .modifier(.control)),
        KeyDef(label: "⌥ opt", action: .modifier(.option)),
        KeyDef(label: "⌘ cmd", width: 1.25, action: .modifier(.command)),
        KeyDef(label: "中/英", width: 1.25, action: .inputSwitch),
        function("", kVK_Space, width: 4),
        function("←", kVK_LeftArrow, repeats: true, optionOnLongPress: true),
        function("↑", kVK_UpArrow, repeats: true),
        function("↓", kVK_DownArrow, repeats: true),
        function("→", kVK_RightArrow, repeats: true, optionOnLongPress: true),
        KeyDef(label: "收起", action: .hide),
    ]
}

enum KeyLayout {
    static let rowUnits: CGFloat = 15

    static func rows(for page: KeyPage) -> [[KeyDef]] {
        page == .letters ? letters : symbols
    }

    private static let letters: [[KeyDef]] = [
        [
            function("esc", kVK_Escape),
            symbol("1", "!"), symbol("2", "@"), symbol("3", "#"), symbol("4", "$"), symbol("5", "%"),
            symbol("6", "^"), symbol("7", "&"), symbol("8", "*"), symbol("9", "("), symbol("0", ")"),
            symbol("-", "_", "–—"), symbol("=", "+", "≠±≈×÷"),
            backspace,
        ],
        [
            function("⇥", kVK_Tab, width: 1.5),
            letter("q", kVK_ANSI_Q), letter("w", kVK_ANSI_W), letter("e", kVK_ANSI_E, "éèêëēė"),
            letter("r", kVK_ANSI_R), letter("t", kVK_ANSI_T), letter("y", kVK_ANSI_Y, "ýÿ"),
            letter("u", kVK_ANSI_U, "úùûüū"), letter("i", kVK_ANSI_I, "íìîïī"), letter("o", kVK_ANSI_O, "óòôöõøōœ"),
            letter("p", kVK_ANSI_P),
            symbol("[", "{", "「」【】"), symbol("]", "}", "『』〔〕"),
            symbol("\\", "|", "、", width: 1.5),
        ],
        [
            KeyDef(label: "⇪", width: 1.75, action: .capsLock),
            letter("a", kVK_ANSI_A, "áàâäãåāæ"), letter("s", kVK_ANSI_S, "ßśš"), letter("d", kVK_ANSI_D),
            letter("f", kVK_ANSI_F), letter("g", kVK_ANSI_G), letter("h", kVK_ANSI_H), letter("j", kVK_ANSI_J),
            letter("k", kVK_ANSI_K), letter("l", kVK_ANSI_L),
            symbol(";", ":"), symbol("'", "\"", "‘’“”"),
            function("↩", kVK_Return, width: 2.25),
        ],
        [
            KeyDef(label: "⇧", width: 2.25, action: .modifier(.shift)),
            letter("z", kVK_ANSI_Z, "žźż"), letter("x", kVK_ANSI_X), letter("c", kVK_ANSI_C, "çćč"),
            letter("v", kVK_ANSI_V), letter("b", kVK_ANSI_B), letter("n", kVK_ANSI_N, "ñń"), letter("m", kVK_ANSI_M),
            symbol(",", "<", "《〈"), symbol(".", ">", "…·》〉"), symbol("/", "?", "¿÷"),
            KeyDef(label: "⇧", width: 2.75, action: .modifier(.shift)),
        ],
        bottomRow(pageKey: KeyDef(label: "&123", width: 1.25, action: .page(.symbols))),
    ]

    // 左边符号，右边数字小键盘
    private static let symbols: [[KeyDef]] = [
        [
            char("`"), char("~"), char("\\", "、"), char("|"), char("{"), char("}"), char("["), char("]"),
            char("<", "《〈≤"), char(">", "》〉≥"),
            char("7"), char("8"), char("9"),
            backspace,
        ],
        [
            char("!", "¡"), char("@"), char("#"), char("$", "¥€£¢"), char("%", "‰"), char("^"), char("&"),
            char("*", "×·"), char(",", "，"), char(".", "…·"),
            char("4"), char("5"), char("6"),
            function("↩", kVK_Return, width: 2),
        ],
        [
            char("("), char(")"), char("-", "–—"), char("_"), char("=", "≠≈"), char("+", "±"), char(";"),
            char(":"), char("'", "‘’"), char("\"", "“”"),
            char("1"), char("2"), char("3"),
            char("?", "¿"), char("/", "÷"),
        ],
        [
            function("esc", kVK_Escape), function("⇥", kVK_Tab),
            edit("撤销", kVK_ANSI_Z), edit("全选", kVK_ANSI_A), edit("剪切", kVK_ANSI_X),
            edit("复制", kVK_ANSI_C), edit("粘贴", kVK_ANSI_V),
            char("0", width: 3),
            function("⌦", kVK_ForwardDelete, width: 2, repeats: true),
        ],
        bottomRow(pageKey: KeyDef(label: "ABC", width: 1.25, action: .page(.letters))),
    ]
}
