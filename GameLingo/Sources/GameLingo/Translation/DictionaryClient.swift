import AVFoundation
import Foundation

/// 點字查詢的結果（ECDICT，由翻譯伺服器查好並轉成台灣正體）
struct WordInfo: Decodable, Equatable {
    struct Entry: Decodable, Equatable {
        let word: String
        let phonetic: String
        let translation: [String]
    }

    let found: Bool
    let query: String?
    let word: String?
    let phonetic: String?
    let translation: [String]?
    let lemma: Entry?
    let error: String?
}

struct DictionaryClient {
    let baseURL: URL

    func lookup(_ word: String) async -> WordInfo? {
        var comps = URLComponents(url: baseURL.appendingPathComponent("lookup"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "word", value: word)]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(WordInfo.self, from: data)
    }
}

/// 單字與整句發音（AVSpeechSynthesizer，系統內建英文語音）
@MainActor
final class SpeechService {
    static let shared = SpeechService()
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synth.speak(u)
    }
}

/// 字根拆解（MorphoLex＋ECDICT wordroot，由翻譯伺服器查好）
struct MorphInfo: Codable, Equatable {
    struct Part: Codable, Equatable, Hashable {
        let type: String      // prefix / root / suffix
        let text: String
        let meaning: String
        let examples: [String]

        /// 顯示用：字首加「-」在後、字尾加「-」在前
        var display: String {
            switch type {
            case "prefix": return text + "-"
            case "suffix": return "-" + text
            default: return text
            }
        }
    }

    let found: Bool
    let word: String?
    let parts: [Part]?

    /// 至少兩個部分才有拆解的意義（只有字根的 rogue、flit 就不顯示）
    var isUseful: Bool { found && (parts?.count ?? 0) >= 2 }
    var roots: [String] { (parts ?? []).filter { $0.type == "root" }.map { $0.text.lowercased() } }
}

extension DictionaryClient {
    func morph(_ word: String) async -> MorphInfo? {
        var comps = URLComponents(url: baseURL.appendingPathComponent("morph"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "word", value: word)]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONDecoder().decode(MorphInfo.self, from: data)
    }
}
