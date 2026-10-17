import Foundation

/// 檔案位置。個人資料放在 ~/Library/Application Support/GameLingo/。
enum AppPaths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameLingo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var history: URL { support.appendingPathComponent("history.jsonl") }
    static var serverLog: URL { support.appendingPathComponent("server.log") }
    static var knownNames: URL { support.appendingPathComponent("known_names.txt") }
    static var appLog: URL { support.appendingPathComponent("app.log") }

    static var crops: URL {
        let url = support.appendingPathComponent("crops", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 專案資料夾（build.sh 編譯時寫進 Info.plist），用來找翻譯伺服器與模型。
    static var repoRoot: URL? {
        if let env = ProcessInfo.processInfo.environment["GAMELINGO_REPO"] {
            return URL(fileURLWithPath: env)
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: "GameLingoRepoRoot") as? String {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// 寫一行到 app.log（出問題時用來查原因）
func appLog(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(message)\n"
    let url = AppPaths.appLog
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}
