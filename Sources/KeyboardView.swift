// 键盘本体：自绘按键，处理点按。顶部一条是拖动条（中间拖动移动、右端拖动改大小）。
// 普通键在按下时就发出，保证跟手；⌫ 和方向键按住并滑动时连发，长按（右键）按词删除/移动。
import AppKit

private struct PlacedKey {
    let def: KeyDef
    /// 整格，用于点按判定（键之间的缝也算在内，避免点空）
    let cell: NSRect
}

private enum DragMode {
    case none
    case key
    case move(startOrigin: NSPoint, startMouse: NSPoint)
    case resize(startFrame: NSRect, startMouse: NSPoint)
}

private enum Palette {
    static let background = dynamic(light: 0.84, dark: 0.13)
    static let key = dynamic(light: 0.99, dark: 0.28)
    static let functionKey = dynamic(light: 0.92, dark: 0.20)
    static let handle = dynamic(light: 0.55, dark: 0.50)

    static func dynamic(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }
    }
}

final class KeyboardView: NSView {
    private let injector: KeyInjector
    private var keys: [PlacedKey] = []
    private var pressedIndex: Int?
    private var dragMode: DragMode = .none
    private var repeatTimer: Timer?
    private var notice: String?
    private var noticeGeneration = 0
    private var inputIsIME = InputSource.isIME

    private let padding: CGFloat = 8
    private let handleHeight: CGFloat = 24
    private let gap: CGFloat = 5
    private let gripWidth: CGFloat = 44

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

    @objc private func inputSourceChanged() {
        inputIsIME = InputSource.isIME
        Diagnostics.shared.log("输入源切换为 \(InputSource.currentID())")
        needsDisplay = true
    }

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - gripWidth, y: 0, width: gripWidth, height: handleHeight)
    }

    private func layoutKeys() {
        keys.removeAll()
        let unit = (bounds.width - padding * 2) / KeyLayout.rowUnits
        let rowHeight = (bounds.height - handleHeight - padding) / CGFloat(KeyLayout.rows.count)
        for (r, row) in KeyLayout.rows.enumerated() {
            var x = padding
            let y = handleHeight + CGFloat(r) * rowHeight
            for def in row {
                let width = def.width * unit
                keys.append(PlacedKey(def: def, cell: NSRect(x: x, y: y, width: width, height: rowHeight)))
                x += width
            }
        }
        needsDisplay = true
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

        Palette.handle.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 32, y: 9, width: 64, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        drawGrip()
        if let notice {
            drawText(notice, at: NSPoint(x: padding + 4, y: 4), size: 11, color: .systemOrange)
        }

        for (i, key) in keys.enumerated() {
            drawKey(key, pressed: i == pressedIndex)
        }
    }

    private func drawGrip() {
        let path = NSBezierPath()
        let right = bounds.maxX - 12
        for offset: CGFloat in [0, 5, 10] {
            path.move(to: NSPoint(x: right - 10 + offset, y: 6))
            path.line(to: NSPoint(x: right, y: 16 - offset))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        Palette.handle.setStroke()
        path.stroke()
    }

    private func drawKey(_ key: PlacedKey, pressed: Bool) {
        let def = key.def
        let rect = key.cell.insetBy(dx: gap / 2, dy: gap / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (def.isCharacter || isSpace(def) ? Palette.key : Palette.functionKey).setFill()
        path.fill()

        var highlighted = false
        if pressed {
            NSColor.controlAccentColor.setFill()
            path.fill()
            highlighted = true
        } else {
            switch def.action {
            case .modifier(let m) where injector.state(of: m) == .locked:
                NSColor.controlAccentColor.setFill()
                path.fill()
                highlighted = true
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - 10, y: rect.maxY - 7, width: 20, height: 3),
                             xRadius: 1.5, yRadius: 1.5).fill()
            case .modifier(let m) where injector.state(of: m) == .once:
                NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
                path.fill()
            case .capsLock where injector.capsLock:
                NSColor.controlAccentColor.setFill()
                path.fill()
                highlighted = true
            default:
                break
            }
        }

        let textColor: NSColor = highlighted ? .white : .labelColor
        let shifted = def.isLetter ? (injector.shiftActive != injector.capsLock) : injector.shiftActive
        let size = def.isCharacter ? min(rect.height * 0.42, 24) : min(rect.height * 0.30, 16)
        drawText(def.label(shifted: shifted), centeredIn: rect, size: size, color: textColor)

        // 角标：符号键在未按 Shift 时提示上档字符；中/英键提示当前输入源
        var hint: String?
        if !def.isLetter && !shifted, let shiftLabel = def.shiftLabel { hint = shiftLabel }
        if case .inputSwitch = def.action { hint = inputIsIME ? "拼" : "A" }
        if let hint {
            drawText(hint, at: NSPoint(x: rect.minX + 5, y: rect.minY + 3), size: size * 0.55,
                     color: highlighted ? .white : .secondaryLabelColor)
        }
    }

    private func isSpace(_ def: KeyDef) -> Bool {
        def.label.isEmpty
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

        if point.y < handleHeight {
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
        point.y < handleHeight ? nil : keys.firstIndex(where: { $0.cell.contains(point) })
    }

    private func press(_ index: Int, event: NSEvent, longPress: Bool) {
        let def = keys[index].def
        Diagnostics.shared.mouseDown(event, key: def.label.isEmpty ? "空格" : def.label, button: longPress ? "右" : "左")
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

    private func trigger(_ def: KeyDef, longPress: Bool = false) {
        var problem: String?
        switch def.action {
        case .key(let code):
            let adding: [Modifier] = longPress && def.optionOnLongPress ? [.option] : []
            problem = injector.tap(code, isLetter: def.isLetter, adding: adding)
        case .modifier(let m):
            injector.toggleModifier(m)
        case .capsLock:
            injector.toggleCaps()
        case .inputSwitch:
            problem = injector.switchInputSource()
        case .hide:
            window?.orderOut(nil)
        }
        if let problem { showNotice(problem) }
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
