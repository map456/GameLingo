import AppKit
import ImageIO

// 命令列測試模式：GameLingo --ocr-test 圖1.png 圖2.png …
// 不開視窗，直接對截圖跑「找對話框 → 前處理 → OCR 投票」，用來驗證 Swift 版 OCR 跟階段 0 一致。
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--ocr-test" {
    OCRTestCLI.run(paths: Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

// 命令列擷取測試：GameLingo --capture-test 輸出.png
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--capture-test" {
    let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/gamelingo-capture.png"
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let img = try await CaptureService().captureOpenEmu()
            let reading = DialogueReader.read(img)
            print("擷取成功 \(img.width)x\(img.height)，對話：\(reading?.text ?? "（沒有對話框）")")
            if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        } catch {
            print("擷取失敗：\(error.localizedDescription)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // 只在選單列出現，不佔 Dock
    app.run()
}
