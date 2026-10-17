import Foundation

/// 一律保留英文的名字（例如自己取的主角名：若叫 Xi，英文字典剛好有 xi 這個字，不保護會被翻成「習」）。
/// 存在 ~/Library/Application Support/GameLingo/known_names.txt，一行一個，# 開頭是註解。
enum KnownNames {
    static let defaultContent = """
    # 一律保留英文、不翻譯的名字，一行一個（# 開頭是註解）。
    # Names that should always stay in English, one per line (lines starting with # are comments).
    # 主角的名字是你自己取的，一定要寫在這裡，例如：
    # Put your hero's name here, e.g.:
    # Xi

    """

    static func load() -> [String] {
        let url = AppPaths.knownNames
        if !FileManager.default.fileExists(atPath: url.path) {
            try? defaultContent.write(to: url, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
