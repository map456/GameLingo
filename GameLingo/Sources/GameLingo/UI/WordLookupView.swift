import SwiftUI

/// 在單字卡、單字本裡「點字查詢」的狀態（查 ECDICT 釋義＋字根拆解）
@MainActor
final class WordLookup: ObservableObject {
    @Published var info: WordInfo?
    @Published var morph: MorphInfo?
    @Published var loading: String?
    /// 這個字是從哪一句點的（收藏時當作遊戲原句；從同字根列表點的就沒有）
    @Published var sentence = ""
    @Published var sentenceZh = ""

    private let client: DictionaryClient
    private var task: Task<Void, Never>?

    init(client: DictionaryClient) {
        self.client = client
    }

    func lookup(_ word: String, sentence: String = "", sentenceZh: String = "") {
        task?.cancel()
        info = nil
        morph = nil
        loading = word
        self.sentence = sentence
        self.sentenceZh = sentenceZh
        task = Task {
            async let i = client.lookup(word)
            async let m = client.morph(word)
            let (info, morph) = await (i, m)
            if Task.isCancelled { return }
            self.loading = nil
            self.morph = morph
            self.info = info ?? WordInfo(found: false, query: word, word: nil, phonetic: nil,
                                         translation: nil, lemma: nil, error: "查詢失敗：翻譯伺服器沒有回應")
        }
    }

    func close() {
        task?.cancel()
        info = nil
        morph = nil
        loading = nil
    }

    /// 收藏的原形（有原形就用原形，例如 restless 本身、disappearing → disappear）
    var headword: String { info?.lemma?.word ?? info?.word ?? info?.query ?? "" }

    func toggleSave(in store: StudyStore) {
        guard let info, info.found, !headword.isEmpty else { return }
        if store.isSaved(headword) {
            store.unsave(headword)
            return
        }
        store.save(word: headword,
                   form: info.query ?? info.word ?? headword,
                   phonetic: info.lemma?.phonetic.isEmpty == false ? info.lemma!.phonetic : (info.phonetic ?? ""),
                   definition: info.lemma?.translation ?? info.translation ?? [],
                   sentence: sentence, sentenceZh: sentenceZh, morph: morph)
    }
}

/// 查詢結果小卡（一般視窗用，淺色深色都可以）
struct WordLookupCard: View {
    @ObservedObject var lookup: WordLookup
    @ObservedObject var store: StudyStore

    var body: some View {
        if lookup.loading != nil || lookup.info != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let w = lookup.loading, lookup.info == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("查詢「\(w)」…").foregroundStyle(.secondary)
                        Spacer()
                        closeButton
                    }
                } else if let info = lookup.info {
                    if info.found {
                        let saved = store.isSaved(lookup.headword)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(info.word ?? info.query ?? "").font(.system(size: 18, weight: .semibold))
                            if let p = info.phonetic, !p.isEmpty {
                                Text("/\(p)/").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            Button { SpeechService.shared.speak(info.word ?? info.query ?? "") } label: {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                            Button { lookup.toggleSave(in: store) } label: {
                                Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
                                    .foregroundStyle(saved ? Color.yellow : Color.primary)
                            }
                            .help(saved ? "從單字本移除" : (lookup.sentence.isEmpty
                                ? "收藏到單字本（沒有遊戲原句，只會有意思卡）"
                                : "收藏到單字本（連同這句原句，會有意思卡和克漏字卡）"))
                            closeButton
                        }
                        if let m = lookup.morph, m.isUseful {
                            MorphChips(morph: m, compact: true)
                        }
                        lines(info.translation ?? [])
                        if let lemma = info.lemma {
                            Text("原形 \(lemma.word)\(lemma.phonetic.isEmpty ? "" : "  /\(lemma.phonetic)/")")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            lines(lemma.translation)
                        }
                    } else {
                        HStack {
                            Text(info.error ?? "字典裡查不到「\(info.query ?? "")」（可能是口音拼寫或專有名詞）")
                                .foregroundStyle(.secondary)
                            Spacer()
                            closeButton
                        }
                    }
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.teal.opacity(0.45), lineWidth: 1))
        }
    }

    private func lines(_ ls: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(ls.prefix(4).enumerated()), id: \.offset) { _, l in
                Text(l).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private var closeButton: some View {
        Button(action: lookup.close) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("關閉")
    }
}
