import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum CaptureError: LocalizedError {
    case noPermission
    case noWindow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission: return "需要「螢幕錄製」權限"
        case .noWindow: return "找不到 OpenEmu 遊戲視窗（請用視窗模式開始遊戲）"
        case .failed(let msg): return "擷取失敗：\(msg)"
        }
    }
}

/// 擷取 OpenEmu 遊戲視窗一張。
///
/// 實測：用 ScreenCaptureKit（SCShareableContent＋SCScreenshotManager）每 0.7 秒擷取一次，
/// 會讓 OpenEmu 收不到鍵盤按鍵；改用階段 0 驗證過的做法——系統視窗清單找視窗、
/// 內建的 screencapture 指令截圖——按鍵就正常。
struct CaptureService {
    static let openEmuBundleID = "org.openemu.OpenEmu"

    func captureOpenEmu() async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) { try Self.captureSync() }.value
    }

    private static func captureSync() throws -> CGImage {
        guard let windowID = findGameWindow() else { throw CaptureError.noWindow }

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamelingo-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(windowID), path]  // -x 不出聲、-o 不含陰影、-l 指定視窗
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
        p.waitUntilExit()

        // 先把整個檔案讀進記憶體再解碼：CGImageSource 是用到時才讀檔，
        // 若直接從檔案建立，defer 刪檔後拿到的會是空白圖（實際踩過這個坑）
        guard p.terminationStatus == 0,
              let data = FileManager.default.contents(atPath: path),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.noPermission }
            throw CaptureError.failed("screencapture 結束碼 \(p.terminationStatus)")
        }
        return image
    }

    /// OpenEmu 有遊戲庫視窗、遊戲視窗、透明的控制列；NDS 上下排列時遊戲視窗是「直的」，挑最直的那個
    private static func findGameWindow() -> CGWindowID? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: openEmuBundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var best: (ratio: CGFloat, id: CGWindowID)?
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 200, bounds.height >= 200,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            let ratio = bounds.height / bounds.width
            if best == nil || ratio > best!.ratio { best = (ratio, id) }
        }
        return best?.id
    }
}
