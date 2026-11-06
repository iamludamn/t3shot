// t3rec — 演示录屏工具：用 ScreenCaptureKit 只录指定 App 的窗口（T3Shot、T3 Code），合成到主显示器画面上。
// 不录其他 App 的窗口，也就不会拍到无关的私人内容。
// 用法：t3rec <输出.mov> <最长秒数> <bundleId> [bundleId…]；收到 SIGINT 或 /tmp/t3rec/stop-rec 出现时正常收尾。
// 编译：swiftc -O -o t3rec t3rec.swift -framework ScreenCaptureKit -framework AVFoundation
import Foundation
import ScreenCaptureKit
import AVFoundation

let a = CommandLine.arguments
guard a.count >= 4 else { fputs("用法：t3rec <out.mov> <秒> <bundleId>…\n", stderr); exit(64) }
let out = URL(fileURLWithPath: a[1]); let maxSec = Double(a[2]) ?? 300; let ids = Set(a[3...])
try? FileManager.default.removeItem(at: out)

final class Rec: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    var stream: SCStream?
    var finished = false
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw NSError(domain: "t3rec", code: 1) }
        let apps = content.applications.filter { ids.contains($0.bundleIdentifier) }
        fputs("display \(display.width)x\(display.height) apps=\(apps.map(\.bundleIdentifier))\n", stderr)
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width; cfg.height = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = false
        cfg.backgroundColor = .black
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        let rc = SCRecordingOutputConfiguration(); rc.outputURL = out; rc.outputFileType = .mov; rc.videoCodecType = .h264
        try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: self))
        try await s.startCapture()
        stream = s
        fputs("recording → \(out.path)\n", stderr)
    }
    func stop() async {
        guard let s = stream else { exit(0) }
        try? await s.stopCapture()
        for _ in 0..<40 where !finished { try? await Task.sleep(for: .milliseconds(100)) }
        exit(0)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fputs("stream stopped: \(error)\n", stderr) }
    func recordingOutputDidFinishRecording(_ o: SCRecordingOutput) { finished = true }
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError error: Error) { fputs("record failed: \(error)\n", stderr); finished = true }
}

let rec = Rec()
signal(SIGINT, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sig.setEventHandler { Task { await rec.stop() } }; sig.resume()
Task {
    do { try await rec.start() } catch { fputs("start failed: \(error)\n", stderr); exit(1) }
    let t0 = Date()
    while Date().timeIntervalSince(t0) < maxSec {
        if FileManager.default.fileExists(atPath: "/tmp/t3rec/stop-rec") { break }
        try? await Task.sleep(for: .milliseconds(300))
    }
    await rec.stop()
}
dispatchMain()
