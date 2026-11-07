// Hotkey.swift — 「左右 Shift 同时按」全局快捷键。
//
// 纯修饰键的组合没法用 Carbon 的 RegisterEventHotKey 注册，所以用只读的 CGEventTap 监听 flagsChanged / keyDown。
// 只读事件监听需要「输入监控」权限（系统设置 → 隐私与安全性 → 输入监控）；没有权限时 tap 建不起来，
// 调用方退回 ⌃⇧4（Carbon，不需要权限），并定时重试，授权后无需重启。
import AppKit
import Carbon.HIToolbox

/// 判定「左右 Shift 同时按下」的状态机：不依赖 CGEvent，可以离线测试。
struct ShiftChord {
    /// 两个 Shift 先后按下的最大间隔：再慢就算「先按住一个，后来又按另一个」，不是同时
    static let window: TimeInterval = 0.4
    /// 触发后的冷却：两个 Shift 一直压着、反复松紧时不连续触发
    static let cooldown: TimeInterval = 1.0

    private var firstDownAt: Date?
    private var dirty = false            // 两个 Shift 之间按过别的键（比如 Shift+字母打大写）：这次不算
    private var wasBoth = false
    private var lastFire = Date.distantPast

    /// 修饰键变化。left / right：左右 Shift 现在是否按着；otherModifiers：⌘ ⌃ ⌥ 是否有按着（有就不算，避免和别的快捷键冲突）。
    /// 返回 true 表示「刚刚同时按下」，应该触发。
    mutating func flagsChanged(left: Bool, right: Bool, otherModifiers: Bool, now: Date = Date()) -> Bool {
        if otherModifiers { reset(); return false }
        if !left && !right { reset(); return false }
        let both = left && right
        defer { wasBoth = both }
        if firstDownAt == nil { firstDownAt = now; dirty = false }      // 从全松开到第一个 Shift 按下
        guard both, !wasBoth, !dirty, let first = firstDownAt else { return false }
        guard now.timeIntervalSince(first) <= Self.window, now.timeIntervalSince(lastFire) >= Self.cooldown else { return false }
        lastFire = now; dirty = true      // dirty：同一次按住不会再触发
        return true
    }

    /// 任何非修饰键按下
    mutating func keyDown() { dirty = true }

    private mutating func reset() { firstDownAt = nil; dirty = false; wasBoth = false }
}

/// 全局监听。回调在主线程。
final class ShiftChordTap: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var chord = ShiftChord()
    private let onFire: @Sendable () -> Void
    private var retry: Timer?

    // 设备相关的修饰键位（IOKit NX_DEVICELSHIFTKEYMASK / NX_DEVICERSHIFTKEYMASK）：CGEventFlags 里区分左右 Shift 靠它们
    private static let leftShift: UInt64 = 0x2
    private static let rightShift: UInt64 = 0x4

    init(onFire: @escaping @Sendable () -> Void) { self.onFire = onFire }

    var isInstalled: Bool { tap != nil }

    /// 建 tap。没有「输入监控」权限时返回 false（同时让系统弹一次授权提示）。
    @discardableResult
    func install(promptForPermission: Bool) -> Bool {
        if tap != nil { return true }
        if !CGPreflightListenEventAccess() {
            if promptForPermission { _ = CGRequestListenEventAccess() }
            return false
        }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ShiftChordTap>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// 没权限时每 5 秒再试一次：用户在系统设置里授权之后不用重启。成功后调用 onInstalled。
    func installWithRetry(onInstalled: @escaping @Sendable () -> Void) {
        if install(promptForPermission: true) { onInstalled(); return }
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self, self.install(promptForPermission: false) else { return }
            t.invalidate(); self.retry = nil
            onInstalled()
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }       // 系统因为回调太慢暂时停掉了 tap，重新打开
        case .keyDown:
            chord.keyDown()
        case .flagsChanged:
            let raw = event.flags.rawValue
            let others = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty == false
            if chord.flagsChanged(left: raw & Self.leftShift != 0, right: raw & Self.rightShift != 0, otherModifiers: others) {
                let f = onFire
                DispatchQueue.main.async { f() }
            }
        default: break
        }
    }
}
