import Foundation
import ServiceManagement

/// 翻譯與語境解說用的本機模型組合
enum TranslationModel: String, CaseIterable {
    case qwen35     // Qwen3.5-9B（8-bit）：翻譯和解說共用一個模型
    case seedx      // Seed-X-PPO-7B 翻譯＋Qwen3-8B 解說（原本的組合）

    var title: String {
        switch self {
        case .qwen35: return "Qwen3.5-9B（翻譯＋解說共用，約 10 GB）"
        case .seedx: return "Seed-X 翻譯＋Qwen3-8B 解說（約 8＋4 GB）"
        }
    }

    /// 伺服器參數用的模型資料夾（相對於專案根目錄）
    var folders: (model: String, explainer: String) {
        switch self {
        case .qwen35: return ("models/qwen3.5-9b-8bit", "models/qwen3.5-9b-8bit")
        case .seedx: return ("models/seedx-mlx-8bit", "models/qwen3-8b-4bit")
        }
    }
}

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
        static let spellingPractice = "spellingPractice"
        static let spellingRepeats = "spellingRepeats"
        static let newWordsPerDay = "newWordsPerDay"
        static let translationModel = "translationModel"
    }

    static let defaults: [String: Any] = [
        Key.autoTranslate: true,
        Key.autoInterval: 1.0,          // 自動翻譯每幾秒看一次畫面
        Key.chineseFontSize: 19.0,      // 最新一句中文的字級（舊句子小 4 級）
        Key.englishFontSize: 15.0,
        Key.panelOpacity: 1.0,
        Key.releaseMemory: true,        // OpenEmu 關掉後卸載翻譯模型
        Key.releaseDelayMinutes: 1.0,
        Key.spellingPractice: false,    // 答錯後要不要照著打幾次這個字（輕鬆版預設關閉）
        Key.spellingRepeats: 2,
        Key.newWordsPerDay: 10,         // 每天最多學幾個新字
        Key.translationModel: TranslationModel.qwen35.rawValue,
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static var autoInterval: Double { max(0.5, UserDefaults.standard.double(forKey: Key.autoInterval)) }
    static var panelOpacity: Double { min(1, max(0.4, UserDefaults.standard.double(forKey: Key.panelOpacity))) }
    static var releaseMemory: Bool { UserDefaults.standard.bool(forKey: Key.releaseMemory) }
    static var spellingPractice: Bool { UserDefaults.standard.bool(forKey: Key.spellingPractice) }
    static var spellingRepeats: Int { min(5, max(1, UserDefaults.standard.integer(forKey: Key.spellingRepeats))) }
    static var translationModel: TranslationModel {
        TranslationModel(rawValue: UserDefaults.standard.string(forKey: Key.translationModel) ?? "") ?? .qwen35
    }
    static var newWordsPerDay: Int { max(1, UserDefaults.standard.integer(forKey: Key.newWordsPerDay)) }
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
