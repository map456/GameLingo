import SwiftUI

/// 單字卡複習。每個收藏的字有兩種卡，交替出現：
/// - 意思卡：正面＝單字＋音標＋遊戲原句（該字加底線）→ 想中文
/// - 克漏字卡：正面＝遊戲原句挖空＋中文翻譯提示 → 想出英文字
/// 背面都有：中文釋義、字根拆解、同字根家族。作答「忘記／困難／普通／簡單」交給 SM-2。
struct FlashcardView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var lookup: WordLookup
    @State private var queue: [ReviewCard] = []
    @State private var showAnswer = false
    @State private var reviewed = 0
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            if let card = queue.first {
                // 不用捲動：視窗高度跟著內容走（StudyWindows 依 SwiftUI 算出的理想高度調整視窗）
                cardView(card)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    // 原句的單字是連結（gamelingo://word/…），點了在下方查字典
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "gamelingo", let w = url.pathComponents.dropFirst().first {
                            lookup.lookup(w, sentence: card.word.sentence, sentenceZh: card.word.sentenceZh)
                        }
                        return .handled
                    })
                answerBar(card)
            } else if loaded {
                doneView
            }
        }
        .frame(width: 600)
        .frame(minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            queue = store.dueCards()
            loaded = true
            lookup.close()
            // 測試用：GAMELINGO_DEBUG_REVIEW=1 時 2 秒後自動翻面（用來量視窗高度）
            if ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_REVIEW"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showAnswer = true }
            }
        }
        .onChange(of: queue.first?.id) { _, _ in lookup.close() }
    }

    // MARK: - 上方進度

    private var progressBar: some View {
        HStack {
            Text("單字卡複習").font(.headline)
            if let card = queue.first {
                Text(card.kind == .cloze ? "克漏字" : "意思")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((card.kind == .cloze ? Color.purple : Color.blue).opacity(0.18), in: Capsule())
            }
            Spacer()
            Text("剩 \(queue.count) 張・已複習 \(reviewed) 次")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - 卡片

    @ViewBuilder
    private func cardView(_ card: ReviewCard) -> some View {
        let w = card.word
        VStack(spacing: 16) {
            if card.kind == .meaning {
                wordHeader(w)
                sentenceBox(Text(Self.linked(w.sentence, target: w.form.isEmpty ? w.word : w.form)), speak: w.sentence)
                    .opacity(w.sentence.isEmpty ? 0 : 1)
            } else {
                Text("想一想：空格裡是哪個英文字？")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                // 翻面前不能點（會看到答案）；翻面後每個字都能點
                sentenceBox(Text(showAnswer ? Self.linked(w.sentence, target: w.form.isEmpty ? w.word : w.form)
                                            : Self.blanked(w.sentence, word: w.form.isEmpty ? w.word : w.form)),
                            speak: showAnswer ? w.sentence : nil)
                if !w.sentenceZh.isEmpty {
                    Text(w.sentenceZh)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if showAnswer { wordHeader(w) }
            }

            if showAnswer { answerDetails(w, kind: card.kind) }
            WordLookupCard(lookup: lookup, store: store)
            if card.kind == .meaning || showAnswer {
                Text("點句子裡的單字或同字根的字可以查字典、收藏")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private func wordHeader(_ w: SavedWord) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(w.word).font(.system(size: 34, weight: .bold))
                Button { SpeechService.shared.speak(w.word) } label: {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help("發音")
            }
            if !w.phonetic.isEmpty {
                Text("/\(w.phonetic)/").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
    }

    private func sentenceBox(_ text: Text, speak: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            text.font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let speak {
                Button { SpeechService.shared.speak(speak) } label: {
                    Image(systemName: "speaker.wave.1").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("整句發音")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 背面：釋義、整句翻譯、字根拆解、同字根家族
    private func answerDetails(_ w: SavedWord, kind: CardKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(w.definition.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let m = w.morph, m.isUseful {
                Divider()
                Text("字根拆解").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                MorphChips(morph: m)
                familyView(w, morph: m)
            }

            if !w.sentenceZh.isEmpty, kind == .meaning {  // 克漏字卡正面已經有中文了
                Divider()
                Text(w.sentenceZh)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 同字根家族：先列單字本裡已收藏的（黃色），再列字典裡的同家族字
    @ViewBuilder
    private func familyView(_ w: SavedWord, morph: MorphInfo) -> some View {
        let saved = store.family(of: w)
        let savedSet = Set(saved.map { $0.word.lowercased() })
        let rootExamples = (morph.parts ?? []).filter { $0.type == "root" }.flatMap(\.examples)
        let others = Array(rootExamples.filter { !savedSet.contains($0.lowercased()) }.prefix(6))
        if !saved.isEmpty || !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("同字根").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(saved) { f in
                        Button { lookup.lookup(f.word, sentence: f.sentence, sentenceZh: f.sentenceZh) } label: {
                            Text("★ \(f.word)")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.yellow.opacity(0.25), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("查「\(f.word)」")
                    }
                    ForEach(others, id: \.self) { e in
                        Button { lookup.lookup(e) } label: {
                            Text(e)
                                .font(.system(size: 12))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("查「\(e)」")
                    }
                }
            }
        }
    }

    // MARK: - 作答

    @ViewBuilder
    private func answerBar(_ card: ReviewCard) -> some View {
        VStack(spacing: 6) {
            if showAnswer {
                HStack(spacing: 10) {
                    ForEach(CardScheduler.Answer.allCases, id: \.rawValue) { a in
                        answerButton(card, a)
                    }
                }
            } else {
                Button { showAnswer = true } label: {
                    Text("顯示答案").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                Text("按空白鍵顯示答案").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private func answerButton(_ card: ReviewCard, _ a: CardScheduler.Answer) -> some View {
        let key = ["1", "2", "3", "4"][CardScheduler.Answer.allCases.firstIndex(of: a)!]
        return Button { answer(card, a) } label: {
            VStack(spacing: 2) {
                Text(a.title).font(.system(size: 14, weight: .semibold))
                Text("\(CardScheduler.preview(card.state, answer: a))・\(key)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .controlSize(.large)
        .tint(Self.color(a))
        .buttonStyle(.bordered)
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
    }

    private func answer(_ card: ReviewCard, _ a: CardScheduler.Answer) {
        store.answer(card, a)
        reviewed += 1
        queue.removeFirst()
        // 忘記的卡片放回這一輪最後面，再考一次
        if a == .again, let w = store.words.first(where: { $0.id == card.word.id }), let st = w.cards[card.kind] {
            queue.append(ReviewCard(word: w, kind: card.kind, state: st))
        }
        showAnswer = false
    }

    // MARK: - 完成

    private var doneView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(store.words.isEmpty ? "單字本還是空的" : "今天的單字卡都複習完了！")
                .font(.title2.bold())
            Text(store.words.isEmpty
                 ? "玩遊戲時點英文單字，在字卡上按「☆ 收藏」就會加進來。"
                 : nextDueText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    private var nextDueText: String {
        guard let next = store.words.map(\.nextDue).min() else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "M 月 d 日"
        return "下一張要複習的卡片在 \(f.string(from: next))。共收藏 \(store.words.count) 個單字。"
    }

    // MARK: - 工具

    /// 原句裡把該字加底線、粗體
    static func highlighted(_ sentence: String, word: String) -> AttributedString {
        var a = AttributedString(sentence)
        if let r = a.range(of: word, options: [.caseInsensitive]) {
            a[r].underlineStyle = .single
            a[r].font = .system(size: 15, weight: .bold)
            a[r].foregroundColor = .orange
        }
        return a
    }

    /// 原句每個字都做成連結（點了查字典），目標字加橘色底線
    static func linked(_ sentence: String, target: String) -> AttributedString {
        var out = AttributedString()
        let ns = sentence as NSString
        let regex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z']*")
        let targetRange = sentence.range(of: target, options: .caseInsensitive).map { NSRange($0, in: sentence) }
        var cursor = 0
        for m in regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let word = ns.substring(with: m.range)
            var piece = AttributedString(word)
            if let enc = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                piece.link = URL(string: "gamelingo://word/\(enc)")
            }
            piece.underlineStyle = .none
            piece.foregroundColor = .primary
            if let t = targetRange, NSIntersectionRange(t, m.range).length > 0 {
                piece.underlineStyle = .single
                piece.font = .system(size: 15, weight: .bold)
                piece.foregroundColor = .orange
            }
            out += piece
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        return out
    }

    /// 克漏字：把該字換成「首字母＋底線」，例如 s＿＿＿＿＿＿＿
    static func blanked(_ sentence: String, word: String) -> AttributedString {
        guard let r = sentence.range(of: word, options: .caseInsensitive) else { return AttributedString(sentence) }
        let original = String(sentence[r])
        let blank = String(original.prefix(1)) + String(repeating: "＿", count: max(2, original.count - 1))
        var a = AttributedString(sentence[..<r.lowerBound])
        var b = AttributedString(blank)
        b.font = .system(size: 15, weight: .bold)
        b.foregroundColor = .purple
        a += b
        a += AttributedString(sentence[r.upperBound...])
        return a
    }

    static func color(_ a: CardScheduler.Answer) -> Color {
        switch a {
        case .again: return .red
        case .hard: return .orange
        case .good: return .blue
        case .easy: return .green
        }
    }
}
