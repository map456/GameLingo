import CoreGraphics
import Foundation
import Vision

/// Apple Vision OCR，加上「多尺寸投票」。
///
/// 階段 0 實測：Vision 對 DQ4 的像素字很敏感，縮放差一點就把 a 認成 o（porty、tolk），
/// 但每次錯的位置不同。所以同一張對話框用 5 種寬度各辨識一次，逐字多數決；
/// 票數相同時優先選「真的英文字」。語言校正開啟（實測開啟較準）。
enum OCRService {
    static let ensembleWidths = [400, 440, 480, 520, 680]

    struct Result {
        let text: String
        let runs: [String]
    }

    /// 單次 Vision 辨識，回傳由上到下排好的各行文字
    static func recognize(_ image: CGImage, languageCorrection: Bool = true) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = languageCorrection
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let observations = request.results ?? []
        // Vision 座標原點在左下，y 大的在上面
        return observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
    }

    /// 對話框裁切圖 → 多尺寸投票後的文字
    static func ensemble(crop: PixelImage) -> Result {
        guard let binary = Preprocessor.binarize(crop) else { return Result(text: "", runs: []) }
        let runs = ensembleWidths.compactMap { width -> String? in
            guard let img = Preprocessor.fit(binary, targetWidth: width) else { return nil }
            let text = TextNormalizer.normalize(recognize(img))
            return text.isEmpty ? nil : text
        }
        return Result(text: vote(runs), runs: runs)
    }

    /// 逐字多數決
    static func vote(_ runs: [String]) -> String {
        guard !runs.isEmpty else { return "" }
        let tokenLists = runs.map { $0.components(separatedBy: " ") }

        // 字數最常見的那一組才參加投票（字數不同代表斷字方式不同，無法逐字對齊）
        var lengthCount: [(len: Int, count: Int)] = []
        for t in tokenLists {
            if let i = lengthCount.firstIndex(where: { $0.len == t.count }) {
                lengthCount[i].count += 1
            } else {
                lengthCount.append((t.count, 1))
            }
        }
        let commonLength = lengthCount.max { $0.count < $1.count }!.len
        let group = tokenLists.filter { $0.count == commonLength }

        var out: [String] = []
        for i in 0..<commonLength {
            // 依第一次出現的順序計票
            var votes: [(token: String, count: Int)] = []
            for t in group {
                if let j = votes.firstIndex(where: { $0.token == t[i] }) {
                    votes[j].count += 1
                } else {
                    votes.append((t[i], 1))
                }
            }
            // 真的英文字多加一票：只在 Vision 自己意見分歧時有作用，
            // 每次都讀成同一個口音拼寫（如 'ere）的字不受影響
            let split = votes.count > 1
            var best = votes[0]
            var bestScore = (-1, false)
            for v in votes {
                let word = EnglishWords.isWord(v.token)
                let score = (v.count + (split && word ? 1 : 0), word)
                if score.0 > bestScore.0 || (score.0 == bestScore.0 && score.1 && !bestScore.1) {
                    best = v
                    bestScore = score
                }
            }
            out.append(best.token)
        }
        return out.joined(separator: " ")
    }
}

/// macOS 內建英文單字表（/usr/share/dict/words），只收小寫開頭的字（大寫開頭的多半是人名地名）。
enum EnglishWords {
    static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var set = Set<String>()
        for line in text.split(separator: "\n") where line.first?.isLowercase == true {
            set.insert(String(line))
        }
        return set
    }()

    static func isWord(_ token: String) -> Bool {
        var core = String(token.filter { $0.isLetter || $0 == "'" }).lowercased()
        core = core.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if core.isEmpty { return true }
        if words.contains(core) { return true }
        if core.hasSuffix("'s"), words.contains(String(core.dropLast(2))) { return true }
        return words.contains(core.replacingOccurrences(of: "n't", with: ""))
    }
}
