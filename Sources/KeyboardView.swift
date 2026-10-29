// 键盘本体：自绘按键，处理点按。顶部一条是拖动条：左端齿轮弹出设置菜单，中间拖动移动，右端拖动改大小（停靠时不能拖）。
// 普通键在按下时就发出，保证跟手；⌫ 和方向键按住并滑动时连发，长按（右键）按词删除/移动。
// 有备选字符的键长按弹出备选面板，再点一下选择。
// 分体布局时左右两半贴两边，中间不画背景，透明处的点按穿透到下面的窗口。
import AppKit

private struct PlacedKey {
    let def: KeyDef
    /// 整格，用于点按判定（键之间的缝也算在内，避免点空）
    let cell: NSRect
}

/// 长按弹出的备选字符：第一个是本键字符（走键码），其余直接输入
private struct AlternatesPopup {
    let def: KeyDef
    let options: [String]
    let cells: [NSRect]
}

private enum DragMode {
    case none
    case key
    case move(startOrigin: NSPoint, startMouse: NSPoint)
    case resize(startFrame: NSRect, startMouse: NSPoint)
}

// 接近 Win11 触摸键盘的配色：字符键最亮，功能键稍暗，按下时变色而不是用强调色
private enum Palette {
    static let background = dynamic(light: 0.93, dark: 0.125)
    static let key = dynamic(light: 1.0, dark: 0.235)
    static let functionKey = dynamic(light: 0.875, dark: 0.18)
    static let pressed = dynamic(light: 0.78, dark: 0.33)
    static let handle = dynamic(light: 0.62, dark: 0.48)
    static let keyShadow = NSColor(name: nil) { appearance in
        NSColor.black.withAlphaComponent(isDark(appearance) ? 0.35 : 0.12)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: isDark(appearance) ? dark : light, alpha: 1)
        }
    }
}

final class KeyboardView: NSView {
    static let handleHeight: CGFloat = 26
    static let padding: CGFloat = 8
    private static let gap: CGFloat = 5
    private static let gripWidth: CGFloat = 44
    private static let gearWidth: CGFloat = 40
    private static let minSplitGap: CGFloat = 40

    static func preferredHeight(rowHeight: CGFloat) -> CGFloat {
        handleHeight + rowHeight * 5 + padding
    }

    /// 标准布局的浮动宽度：键宽约为行高的 1.05 倍
    static func standardWidth(rowHeight: CGFloat) -> CGFloat {
        (rowHeight * 1.05 * KeyLayout.rowUnits + padding * 2).rounded()
    }

    private let injector: KeyInjector
    private var keys: [PlacedKey] = []
    /// 画背景的区域：标准布局一块，分体布局左右两块
    private var panes: [NSRect] = []
    private var pressedIndex: Int?
    private var dragMode: DragMode = .none
    private var repeatTimer: Timer?
    private var notice: String?
    private var noticeGeneration = 0
    private var inputIsIME = InputSource.isIME
    private var page: KeyPage = .letters
    private var popup: AlternatesPopup?

    init(injector: KeyInjector) {
        self.injector = injector
        super.init(frame: .zero)
        injector.onStateChange = { [weak self] in self?.needsDisplay = true }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged),
            name: InputSource.changedNotification, object: nil, suspensionBehavior: .deliverImmediately)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override var isFlipped: Bool { true }
    // 第一次点按就生效，不需要先点一下“激活”窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutKeys()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 布局、停靠等设置变了（窗口大小可能没变），重新排键
    func settingsChanged() {
        layoutKeys()
    }

    @objc private func inputSourceChanged() {
        inputIsIME = InputSource.isIME
        Diagnostics.shared.log("输入源切换为 \(InputSource.currentID())")
        needsDisplay = true
    }

    private var gearRect: NSRect {
        NSRect(x: panes.first?.minX ?? 0, y: 0, width: Self.gearWidth, height: Self.handleHeight)
    }

    private var gripRect: NSRect {
        NSRect(x: (panes.last ?? bounds).maxX - Self.gripWidth, y: 0, width: Self.gripWidth, height: Self.handleHeight)
    }

    // MARK: 布局

    private func layoutKeys() {
        keys.removeAll()
        popup = nil
        pressedIndex = nil
        let padding = Self.padding
        let rowHeight = (bounds.height - Self.handleHeight - padding) / CGFloat(KeyLayout.rows(for: page).count)

        if Settings.shared.split {
            // 键接近方形，两半贴两边，剩下的都是中间的空隙；窗口太窄时缩小键
            let half = KeyLayout.splitHalfUnits
            let unit = max(1, min(rowHeight * 1.1, (bounds.width - padding * 4 - Self.minSplitGap) / (half * 2)))
            let paneWidth = half * unit + padding * 2
            panes = [
                NSRect(x: 0, y: 0, width: paneWidth, height: bounds.height),
                NSRect(x: bounds.maxX - paneWidth, y: 0, width: paneWidth, height: bounds.height),
            ]
            for (r, row) in KeyLayout.splitRows(for: page).enumerated() {
                let y = Self.handleHeight + CGFloat(r) * rowHeight
                place(row.left, fromX: padding, y: y, unit: unit, height: rowHeight)
                let rightWidth = row.right.reduce(0) { $0 + $1.width } * unit
                place(row.right, fromX: bounds.maxX - padding - rightWidth, y: y, unit: unit, height: rowHeight)
            }
        } else {
            panes = [bounds]
            let unit = (bounds.width - padding * 2) / KeyLayout.rowUnits
            for (r, row) in KeyLayout.rows(for: page).enumerated() {
                place(row, fromX: padding, y: Self.handleHeight + CGFloat(r) * rowHeight, unit: unit, height: rowHeight)
            }
        }
        needsDisplay = true
        // 窗口阴影按透明区域算，分体时要等重画后更新
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }

    private func place(_ row: [KeyDef], fromX startX: CGFloat, y: CGFloat, unit: CGFloat, height: CGFloat) {
        var x = startX
        for def in row {
            let width = def.width * unit
            keys.append(PlacedKey(def: def, cell: NSRect(x: x, y: y, width: width, height: height)))
            x += width
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let docked = Settings.shared.docked
        for pane in panes {
            Palette.background.setFill()
            NSBezierPath(roundedRect: pane, xRadius: 10, yRadius: 10).fill()
            if !docked {
                Palette.handle.setFill()
                NSBezierPath(roundedRect: NSRect(x: pane.midX - 24, y: 10, width: 48, height: 4), xRadius: 2, yRadius: 2).fill()
            }
        }
        drawSymbol("gearshape", in: gearRect, size: 13, color: .secondaryLabelColor)
        if !docked { drawGrip() }
        if let notice {
            drawText(notice, at: NSPoint(x: gearRect.maxX, y: 5), size: 11, color: .systemOrange)
        }

        for (i, key) in keys.enumerated() {
            drawKey(key, pressed: i == pressedIndex)
        }
        if let popup { drawPopup(popup) }
    }

    private func drawGrip() {
        let path = NSBezierPath()
        let right = gripRect.maxX - 12
        for offset: CGFloat in [0, 5, 10] {
            path.move(to: NSPoint(x: right - 10 + offset, y: 7))
            path.line(to: NSPoint(x: right, y: 17 - offset))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        Palette.handle.setStroke()
        path.stroke()
    }

    private func drawKey(_ key: PlacedKey, pressed: Bool) {
        let def = key.def
        let rect = key.cell.insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        // 底边一道细阴影，接近 Win11 键帽
        Palette.keyShadow.setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        (def.isCharacter || isSpace(def) ? Palette.key : Palette.functionKey).setFill()
        path.fill()

        var highlighted = false
        if pressed {
            Palette.pressed.setFill()
            path.fill()
        } else {
            switch def.action {
            case .modifier(let m) where injector.state(of: m) != .off:
                NSColor.controlAccentColor.setFill()
                path.fill()
                highlighted = true
                if injector.state(of: m) == .locked {
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: NSRect(x: rect.midX - 10, y: rect.maxY - 7, width: 20, height: 3),
                                 xRadius: 1.5, yRadius: 1.5).fill()
                }
            case .capsLock where injector.capsLock:
                NSColor.controlAccentColor.setFill()
                path.fill()
                highlighted = true
            default:
                break
            }
        }

        let textColor: NSColor = highlighted ? .white : .labelColor
        let shifted = isShifted(def)
        let iconDrawn = symbolName(for: def).map {
            drawSymbol($0, in: rect, size: min(rect.height * 0.32, 18), color: textColor)
        } ?? false
        if !iconDrawn {
            let size = def.isCharacter ? min(rect.height * 0.42, 24) : min(rect.height * 0.30, 16)
            drawText(label(for: def, shifted: shifted), centeredIn: rect, size: size, color: textColor)
        }

        // 角标：字母页的符号键在未按 ⇧ 时提示上档字符
        if !def.isLetter && !shifted, let shiftLabel = def.shiftLabel {
            drawText(shiftLabel, at: NSPoint(x: rect.minX + 5, y: rect.minY + 3),
                     size: min(rect.height * 0.42, 24) * 0.55, color: .secondaryLabelColor)
        }
    }

    private func symbolName(for def: KeyDef) -> String? {
        switch def.action {
        case .modifier(.shift):
            return injector.state(of: .shift) == .off ? "shift" : "shift.fill"
        case .capsLock:
            return injector.capsLock ? "capslock.fill" : "capslock"
        default:
            return def.symbol
        }
    }

    private func label(for def: KeyDef, shifted: Bool) -> String {
        if case .inputSwitch = def.action { return inputIsIME ? "中" : "英" }
        return def.label(shifted: shifted)
    }

    private func drawPopup(_ popup: AlternatesPopup) {
        guard let first = popup.cells.first, let last = popup.cells.last else { return }
        let frame = first.union(last).insetBy(dx: -4, dy: -4)
        let background = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        Palette.functionKey.setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setStroke()
        background.lineWidth = 1.5
        background.stroke()

        for (option, cell) in zip(popup.options, popup.cells) {
            let rect = cell.insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
            Palette.key.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            drawText(option, centeredIn: rect, size: min(rect.height * 0.42, 24), color: .labelColor)
        }
    }

    /// 字母看 ⇧ 和大写锁定；字母页的符号键只看 ⇧；符号页的字符键固定显示本字符
    private func isShifted(_ def: KeyDef) -> Bool {
        if def.isLetter { return injector.shiftActive != injector.capsLock }
        return def.ignoresStickyShift ? false : injector.shiftActive
    }

    private func isSpace(_ def: KeyDef) -> Bool {
        def.label.isEmpty
    }

    @discardableResult
    private func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, color: NSColor) -> Bool {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return false }
        let s = image.size
        image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return true
    }

    private func drawText(_ text: String, centeredIn rect: NSRect, size: CGFloat, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ])
        let s = string.size()
        string.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
    }

    private func drawText(_ text: String, at point: NSPoint, size: CGFloat, color: NSColor) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
        ]).draw(at: point)
    }

    // MARK: 点按

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let window else { return }

        // 备选面板开着时：点到备选就输入，点别处只收起面板（和 Win11 一样）
        if let popup {
            self.popup = nil
            needsDisplay = true
            if let i = popup.cells.firstIndex(where: { $0.contains(point) }) {
                Diagnostics.shared.mouseDown(event, key: "备选 \(popup.options[i])")
                choose(i, in: popup)
            } else {
                Diagnostics.shared.mouseDown(event, key: "收起备选")
            }
            return
        }

        if point.y < Self.handleHeight {
            if gearRect.contains(point) {
                Diagnostics.shared.mouseDown(event, key: "设置")
                showSettingsMenu()
                return
            }
            guard !Settings.shared.docked, panes.contains(where: { $0.contains(point) }) else { return }
            Diagnostics.shared.mouseDown(event, key: "拖动条")
            if gripRect.contains(point) {
                dragMode = .resize(startFrame: window.frame, startMouse: NSEvent.mouseLocation)
            } else {
                dragMode = .move(startOrigin: window.frame.origin, startMouse: NSEvent.mouseLocation)
            }
            return
        }

        guard let index = keyIndex(at: point) else {
            Diagnostics.shared.mouseDown(event, key: nil)
            return
        }
        press(index, event: event, longPress: false)
    }

    private func keyIndex(at point: NSPoint) -> Int? {
        point.y < Self.handleHeight ? nil : keys.firstIndex(where: { $0.cell.contains(point) })
    }

    private func press(_ index: Int, event: NSEvent, longPress: Bool) {
        let def = keys[index].def
        Diagnostics.shared.mouseDown(event, key: def.label.isEmpty ? "空格" : def.label, button: longPress ? "右" : "左")
        if longPress && !def.alternates.isEmpty {
            showAlternates(for: keys[index])
            return
        }
        pressedIndex = index
        dragMode = .key
        needsDisplay = true

        trigger(def, longPress: longPress)
        Diagnostics.shared.injected(after: event)
        // 长按的右键按下和抬起是同时到的，没法连发；连发只在“按住并滑动”时有（驱动这时实时上报左键）
        if def.repeats && !longPress { startRepeat(def) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        switch dragMode {
        case .move(let startOrigin, let startMouse):
            window.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                          y: startOrigin.y + mouse.y - startMouse.y))
        case .resize(let startFrame, let startMouse):
            // 右上角拖动：左下角不动
            let width = max(window.minSize.width, startFrame.width + mouse.x - startMouse.x)
            let height = max(window.minSize.height, startFrame.height + mouse.y - startMouse.y)
            window.setFrame(NSRect(x: startFrame.minX, y: startFrame.minY, width: width, height: height), display: true)
        case .key:
            Diagnostics.shared.mouseDragged()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        Diagnostics.shared.mouseUp(event)
        stopRepeat()
        if pressedIndex != nil {
            pressedIndex = nil
            needsDisplay = true
        }
        dragMode = .none
    }

    // VoodooI2C 触摸屏（实测）：点按在手指抬起时一次性发左键按下+抬起；手指不动按住，到时间就在按住期间
    // 一次性发右键按下+抬起；按住后滑动则实时发左键按下/拖动/抬起。所以右键就是“长按”。
    override func rightMouseDown(with event: NSEvent) {
        if popup != nil {
            popup = nil
            needsDisplay = true
            return
        }
        guard let index = keyIndex(at: convert(event.locationInWindow, from: nil)) else {
            Diagnostics.shared.unexpected(event, "右键按下（不在键上）")
            return
        }
        Diagnostics.shared.count("长按（右键）")
        press(index, event: event, longPress: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        Diagnostics.shared.mouseDragged()
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        Diagnostics.shared.unexpected(event, "其他鼠标键按下")
    }

    override func pressureChange(with event: NSEvent) {
        Diagnostics.shared.count("压力事件")
    }

    private func showSettingsMenu() {
        let menu = NSMenu()
        Settings.shared.addItems(to: menu)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "收起键盘", action: #selector(hideKeyboard), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.popUp(positioning: nil, at: NSPoint(x: gearRect.minX + 6, y: gearRect.maxY), in: self)
    }

    @objc private func hideKeyboard() {
        window?.orderOut(nil)
    }

    private func trigger(_ def: KeyDef, longPress: Bool = false) {
        var problem: String?
        switch def.action {
        case .key(let code):
            let adding = def.fixedModifiers + (longPress && def.optionOnLongPress ? [.option] : [])
            problem = injector.tap(code, isLetter: def.isLetter, adding: adding,
                                   ignoreStickyShift: def.ignoresStickyShift)
        case .modifier(let m):
            injector.toggleModifier(m)
        case .capsLock:
            injector.toggleCaps()
        case .inputSwitch:
            problem = injector.switchInputSource()
        case .page(let target):
            page = target
            layoutKeys()
        case .hide:
            window?.orderOut(nil)
        }
        if let problem { showNotice(problem) }
    }

    /// 备选面板盖在键的上一行（第一行的键往下一行盖），每格和键一样高，第一格对准本键
    private func showAlternates(for key: PlacedKey) {
        let def = key.def
        let shifted = isShifted(def)
        let alternates = def.alternates.map { a -> String in
            guard def.isLetter && shifted else { return a }
            let upper = a.uppercased()
            return upper.count == 1 ? upper : a  // ß 的大写是 SS，保留原样
        }
        let options = [def.label(shifted: shifted)] + alternates
        let height = key.cell.height
        let width = max(key.cell.width, height * 0.9)
        let total = width * CGFloat(options.count)
        let x = min(max(key.cell.minX, Self.padding), bounds.width - Self.padding - total)
        let y = key.cell.minY - height < Self.handleHeight ? key.cell.maxY : key.cell.minY - height
        let cells = options.indices.map { NSRect(x: x + CGFloat($0) * width, y: y, width: width, height: height) }
        popup = AlternatesPopup(def: def, options: options, cells: cells)
        needsDisplay = true
    }

    private func choose(_ index: Int, in popup: AlternatesPopup) {
        if index == 0 {
            trigger(popup.def)
        } else if let problem = injector.type(popup.options[index]) {
            showNotice(problem)
        }
    }

    private func startRepeat(_ def: KeyDef) {
        stopRepeat()
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let repeating = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trigger(def) }
                }
                RunLoop.main.add(repeating, forMode: .common)
                self.repeatTimer = repeating
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeGeneration += 1
        let generation = noticeGeneration
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.noticeGeneration == generation else { return }
            self.notice = nil
            self.needsDisplay = true
        }
    }
}
