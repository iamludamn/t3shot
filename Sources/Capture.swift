// Capture.swift — 整屏截图。三种方式，按速度排序后选默认（--bench-capture 实测）：
//   sck       ScreenCaptureKit，进程内直接拿 CGImage：不起子进程、不写文件、不编码 PNG
//   cli-tiff  screencapture 输出未压缩 TIFF：省掉 PNG 压缩
//   cli-png   screencapture 输出 PNG（最初的做法，Retina 整屏编码一次要几百毫秒）
// T3SHOT_CAPTURE=sck|cli-tiff|cli-png 可强制指定；sck 失败会自动退回 cli-png。
import AppKit
@preconcurrency import ScreenCaptureKit

enum ScreenGrabber {
    enum Method: String, CaseIterable { case sck, cliTIFF = "cli-tiff", cliPNG = "cli-png" }

    static var preferred: Method {
        getenv("T3SHOT_CAPTURE").flatMap { Method(rawValue: String(cString: $0)) } ?? .sck
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 鼠标所在的屏幕
    static func screenUnderMouse() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main
    }

    // MARK: ScreenCaptureKit

    /// SCShareableContent 第一次取很慢（几百毫秒），缓存显示器列表；屏幕配置变了再清掉
    private actor Displays {
        var cache: [CGDirectDisplayID: SCDisplay] = [:]
        func display(_ id: CGDirectDisplayID) async throws -> SCDisplay {
            if let d = cache[id] { return d }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cache = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
            guard let d = cache[id] else { throw T3Error("ScreenCaptureKit 找不到显示器 \(id)") }
            return d
        }
        func invalidate() { cache = [:] }
    }
    private static let displays = Displays()
    static func screenConfigurationChanged() { Task { await displays.invalidate() } }

    static func grabSCK(_ screen: NSScreen) async throws -> CGImage {
        guard let id = displayID(screen) else { throw T3Error("没有显示器 ID") }
        let d = try await displays.display(id)
        let cfg = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        cfg.width = Int((screen.frame.width * scale).rounded()); cfg.height = Int((screen.frame.height * scale).rounded())
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
    }

    /// 启动时预热：把显示器列表取好，第一次按快捷键就不用付这个代价
    static func prewarm() async {
        guard preferred == .sck, let s = NSScreen.main, let id = displayID(s) else { return }
        _ = try? await displays.display(id)
    }

    // MARK: screencapture 命令行

    static func grabCLI(_ screen: NSScreen, format: String) async -> CGImage? {
        let r = screen.frame
        guard let primary = NSScreen.screens.first else { return nil }
        // -R 用全局坐标（左上角为原点，主屏左上为 0,0）：多块屏幕也对
        let rect = "\(Int(r.minX)),\(Int(primary.frame.height - r.maxY)),\(Int(r.width)),\(Int(r.height))"
        let tmp = NSTemporaryDirectory() + "t3shot-full-\(UUID().uuidString).\(format)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        return await Task.detached { () -> CGImage? in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", format, "-R", rect, tmp]
            try? p.run(); p.waitUntilExit()
            // ShouldCacheImmediately：在这里（后台）就解码，别留到第一次绘制时堵住主线程
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
    }

    // MARK: 入口

    static func grab(_ screen: NSScreen, method: Method? = nil) async -> CGImage? {
        switch method ?? preferred {
        case .sck:
            if let img = try? await grabSCK(screen) { return img }
            if Perf.enabled { fputs("[perf] ScreenCaptureKit 失败，退回 screencapture\n", stderr) }
            return await grabCLI(screen, format: "png")
        case .cliTIFF: return await grabCLI(screen, format: "tiff")
        case .cliPNG: return await grabCLI(screen, format: "png")
        }
    }

    /// 像素 → 点：NSImage 的 size 用点，representation 保留真实像素（Canvas 按像素算导出尺寸）
    static func nsImage(_ cg: CGImage, screen: NSScreen) -> NSImage {
        let s = screen.backingScaleFactor
        let img = NSImage(size: NSSize(width: Double(cg.width) / s, height: Double(cg.height) / s))
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = img.size
        img.addRepresentation(rep)
        return img
    }
}
