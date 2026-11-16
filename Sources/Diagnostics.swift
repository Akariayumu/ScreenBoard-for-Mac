// P0 诊断：记录点按延迟、按住时长、驱动送来的异常事件（右键等）、安全输入，用来实测风险 1–4。
// 日志写到 ~/Library/Logs/ScreenBoard/p0.log，菜单栏可以看摘要、复制摘要。
import AppKit
import Carbon

final class Diagnostics {
    static let shared = Diagnostics()

    let logURL: URL
    private var handle: FileHandle?
    private let maxSamples = 500
    // 毫秒
    private var deliverLatencies: [Double] = []
    private var injectLatencies: [Double] = []
    private var holdDurations: [Double] = []
    private var counts: [String: Int] = [:]
    private var downTimestamp: TimeInterval?
    private var dragsDuringPress = 0
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenBoard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("p0.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
    }

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    func count(_ name: String) {
        counts[name, default: 0] += 1
        log("计数 \(name)")
    }

    // MARK: 鼠标事件（触摸屏点按到应用里就是鼠标事件）

    /// event.timestamp 是系统开机以来的秒数，和 systemUptime 同一基准；差值是事件从系统生成到本程序处理的时间
    func mouseDown(_ event: NSEvent, key: String?, button: String = "左") {
        let deliver = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
        append(&deliverLatencies, deliver)
        downTimestamp = event.timestamp
        dragsDuringPress = 0
        log(String(format: "%@键 down key=%@ 送达 %.1fms subtype=%ld pressure=%.2f clickCount=%ld",
                   button, key ?? "-", deliver, Int(event.subtype.rawValue), event.pressure, event.clickCount))
    }

    func injected(after event: NSEvent) {
        append(&injectLatencies, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
    }

    func mouseDragged() {
        dragsDuringPress += 1
    }

    func mouseUp(_ event: NSEvent) {
        guard let down = downTimestamp else { return }
        let hold = (event.timestamp - down) * 1000
        append(&holdDurations, hold)
        downTimestamp = nil
        log(String(format: "%@键 up 按住 %.0fms 拖动事件 %ld 个",
                   event.type == .rightMouseUp ? "右" : "左", hold, dragsDuringPress))
        if dragsDuringPress > 0 { count("按键中出现拖动") }
    }

    /// 风险 6：别的应用里每次左键按下前 1 秒内的光标移动（距今毫秒、dx、dy）。
    /// 已确认 CGEvent 字段分不出手指和触控板，看移动能不能分
    func clickSource(_ event: NSEvent, moves: [(ago: Double, dx: Double, dy: Double)]) {
        let detail = moves.suffix(5).map { String(format: "%.0fms(%.0f,%.0f)", $0.ago * 1000, $0.dx, $0.dy) }
        log("别处点击 点前1秒移动 \(moves.count) 次 " + detail.joined(separator: " "))
    }

    func unexpected(_ event: NSEvent, _ name: String) {
        count(name)
        log(String(format: "%@ subtype=%ld clickCount=%ld", name, Int(event.subtype.rawValue), event.clickCount))
    }

    func reset() {
        deliverLatencies.removeAll()
        injectLatencies.removeAll()
        holdDurations.removeAll()
        counts.removeAll()
        log("诊断计数已重置")
    }

    // MARK: 摘要

    func summaryLines() -> [String] {
        var lines: [String] = []
        if deliverLatencies.isEmpty {
            lines.append("还没有点按记录")
        } else {
            lines.append(String(format: "点按 %ld 次｜送达 平均 %.1fms，P95 %.1fms，最大 %.1fms",
                                deliverLatencies.count, mean(deliverLatencies),
                                percentile(deliverLatencies, 0.95), deliverLatencies.max() ?? 0))
        }
        if !injectLatencies.isEmpty {
            lines.append(String(format: "到发出按键 平均 %.1fms，最大 %.1fms",
                                mean(injectLatencies), injectLatencies.max() ?? 0))
        }
        if !holdDurations.isEmpty {
            lines.append(String(format: "按住时长 中位 %.0fms，最长 %.0fms",
                                percentile(holdDurations, 0.5), holdDurations.max() ?? 0))
        }
        for (name, n) in counts.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name)：\(n) 次")
        }
        lines.append("安全输入当前：\(IsSecureEventInputEnabled() ? "开启" : "关闭")")
        return lines
    }

    func summaryText() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "ScreenBoard P0 诊断（\(version)，macOS \(os)）",
            "辅助功能权限：\(AXIsProcessTrusted() ? "已授权" : "未授权")",
            "当前输入源：\(InputSource.currentID())",
        ]
        lines += summaryLines()
        return lines.joined(separator: "\n")
    }

    private func append(_ samples: inout [Double], _ value: Double) {
        samples.append(value)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * p))
        return sorted[index]
    }
}
