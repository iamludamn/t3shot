// Perf.swift — 从按下快捷键到窗口出现的耗时打点。T3SHOT_TIMING=1 时每个节点打印到 stderr；--bench-open 用它出报告。
import Foundation

enum Perf {
    nonisolated(unsafe) static var t0 = Date()
    nonisolated(unsafe) static var marks: [(name: String, ms: Double)] = []
    /// 下一次 Canvas 首次绘制时打 first-frame 节点（图片真正画出来）
    nonisolated(unsafe) static var awaitFirstFrame = false
    static var enabled: Bool { getenv("T3SHOT_TIMING") != nil }

    static func start() { t0 = Date(); marks = []; awaitFirstFrame = true; mark("trigger") }
    static func mark(_ name: String) {
        let ms = Date().timeIntervalSince(t0) * 1000
        marks.append((name, ms))
        if enabled { fputs(String(format: "[perf] %6.0f ms  %@\n", ms, name), stderr) }
    }
    static func ms(_ name: String) -> Double? { marks.first { $0.name == name }?.ms }
}
