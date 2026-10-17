import Foundation
import ServiceManagement

/// 使用者設定（存在 UserDefaults）。設定視窗用 @AppStorage 綁同樣的 key。
enum AppSettings {
    enum Key {
        static let autoTranslate = "autoTranslate"
        static let autoInterval = "autoInterval"
        static let chineseFontSize = "chineseFontSize"
        static let englishFontSize = "englishFontSize"
        static let panelOpacity = "panelOpacity"
        static let releaseMemory = "releaseMemory"
        static let releaseDelayMinutes = "releaseDelayMinutes"
    }

    static let defaults: [String: Any] = [
        Key.autoTranslate: true,
        Key.autoInterval: 1.0,          // 自動翻譯每幾秒看一次畫面
        Key.chineseFontSize: 19.0,      // 最新一句中文的字級（舊句子小 4 級）
        Key.englishFontSize: 15.0,
        Key.panelOpacity: 1.0,
        Key.releaseMemory: true,        // OpenEmu 關掉後卸載翻譯模型
        Key.releaseDelayMinutes: 1.0,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static var autoInterval: Double { max(0.5, UserDefaults.standard.double(forKey: Key.autoInterval)) }
    static var panelOpacity: Double { min(1, max(0.4, UserDefaults.standard.double(forKey: Key.panelOpacity))) }
    static var releaseMemory: Bool { UserDefaults.standard.bool(forKey: Key.releaseMemory) }
    static var releaseDelay: Double { UserDefaults.standard.double(forKey: Key.releaseDelayMinutes) * 60 }

    /// 開機自動啟動（登入項目）
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appLog("設定開機啟動失敗：\(error.localizedDescription)")
            }
        }
    }
}
