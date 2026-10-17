import Foundation

/// OCR 文字清理：合併斷行、去說話者標記與翻頁符號、統一引號。
enum TextNormalizer {
    static func normalize(_ lines: [String]) -> String {
        var text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        text = text.replacingOccurrences(of: #"^\s*[*＊]\s*:?\s*"#, with: "", options: .regularExpression)  // 「*:」或 OCR 多讀的「*」
        text = text.replacingOccurrences(of: #"\s*[▼▽◆◇♦]\s*$"#, with: "", options: .regularExpression)    // 翻頁符號
        text = text.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        text = text.replacingOccurrences(of: #"(\w)- (\w)"#, with: "$1$2", options: .regularExpression)  // 行尾連字號斷字
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = stripTrailingJunk(text.trimmingCharacters(in: .whitespaces))
        return text
    }

    /// 對話框角落閃爍的「下一頁」箭頭常被讀成「40 • •」「• ca... •」之類的雜訊。
    /// 從前往後找第一個句尾標點（. ! ? … ' "），如果它後面全是雜訊就刪掉。
    /// 雜訊＝完全沒有字母（「40」），或有圓點符號而且沒有 3 個字母以上的單字（「• ca... •」）。
    /// 「Yes. No.」這種真正的短句、或「I'm sure…」這種後面還有整句話的，都不會被刪。
    static func stripTrailingJunk(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[.!?…'"]+"#) else { return text }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            guard end < ns.length else { return text }
            let tail = ns.substring(from: end)
            let hasBullet = tail.contains { "•·●▼▽◆◇♦".contains($0) }
            let hasLetter = tail.contains { $0.isLetter }
            let hasRealWord = tail.range(of: #"[A-Za-z]{3,}"#, options: .regularExpression) != nil
            if !hasLetter || (hasBullet && !hasRealWord) {
                return ns.substring(to: end).trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }
}
