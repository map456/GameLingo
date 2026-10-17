import AppKit
import CoreGraphics

/// 螢幕錄製權限（擷取 OpenEmu 視窗需要）。
enum Permissions {
    static var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// 第一次會跳出系統詢問視窗；之後只會回傳目前狀態。
    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
