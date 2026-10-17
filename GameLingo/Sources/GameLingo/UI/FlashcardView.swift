import SwiftUI

/// 單字卡複習。每個收藏的字有兩種卡，交替出現：
/// - 意思卡：正面＝單字＋音標＋遊戲原句（該字加底線）→ 想中文
/// - 克漏字卡：正面＝遊戲原句挖空＋中文翻譯提示 → 想出英文字
/// 背面都有：中文釋義、字根拆解、同字根家族。作答「忘記／困難／普通／簡單」交給 SM-2。
/// 今天的卡複習完可以「再練一輪」（全部或只練忘記過的），練習不改變 SM-2 排程。
/// 按「忘記」後（設定可關）要把這個字打對幾次才換下一張；右上角垃圾桶可把這個字從單字本刪掉。
struct FlashcardView: View {
    @ObservedObject var store: StudyStore
    @ObservedObject var lookup: WordLookup
    @State private var queue: [ReviewCard] = []
    @State private var showAnswer = false
    @State private var reviewed = 0
    @State private var loaded = false
    // 拼字練習：按「忘記」後要打對 spellingRepeats 次
    @State private var spelling: ReviewCard?
    @State private var spellInput = ""
    @State private var spellCount = 0
    @State private var spellWrong = false
    @FocusState private var spellFocused: Bool
    @State private var confirmDelete = false
    @State private var practice = false   // 額外練習：不寫入排程
    // 克漏字卡：正面可以先打答案，按 Return 翻面並顯示對錯
    @State private var clozeInput = ""
    @State private var clozeResult: Bool?
    @FocusState private var clozeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            if let card = queue.first {
                // 不用捲動：視窗高度跟著內容走（StudyWindows 依 SwiftUI 算出的理想高度調整視窗）
                cardView(card)
                    .padding(.top, 6)
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
        .frame(minHeight: 480, alignment: .top)
        .background(ThemeBackground())
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onAppear {
            queue = store.dueCards()
            if queue.isEmpty, ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_PRACTICE"] == "1" {
                startPractice(onlyLapsed: false)  // 測試用：沒有到期卡時直接進練習
            }
            loaded = true
            lookup.close()
            focusClozeIfNeeded()
            // 測試用：GAMELINGO_DEBUG_REVIEW=1 時 2 秒後自動翻面（用來量視窗高度）
            if ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_REVIEW"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showAnswer = true }
            }
            // 測試用：GAMELINGO_DEBUG_LOOKUP=字 時 3 秒後自動查這個字
            if let w = ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_LOOKUP"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lookup.lookup(w) }
            }
        }
        .onChange(of: queue.first?.id) { _, _ in
            lookup.close()
            clozeInput = ""
            clozeResult = nil
            focusClozeIfNeeded()
        }
    }

    // MARK: - 上方進度

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(practice ? "額外練習" : "單字卡複習").font(Theme.rounded(24, .heavy))
                    Text(practice ? "不影響下次複習的日期" : "剩 \(queue.count) 張・已複習 \(reviewed) 次")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let card = queue.first {
                    TagPill(text: card.kind == .cloze ? "克漏字" : "意思",
                            color: card.kind == .cloze ? Theme.pink : Theme.teal)
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 30))
                    .help("把「\(card.word.word)」從單字本刪除")
                    .confirmationDialog("要刪除「\(card.word.word)」嗎？", isPresented: $confirmDelete) {
                        Button("刪除", role: .destructive) { delete(card) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("會從單字本移除，意思卡和克漏字卡都不再出現。之後可以在遊戲裡重新收藏。")
                    }
                }
            }
            if !queue.isEmpty {
                GradientProgressBar(value: Double(reviewed) / Double(max(1, reviewed + queue.count)))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - 卡片

    @ViewBuilder
    private func cardView(_ card: ReviewCard) -> some View {
        let w = card.word
        VStack(spacing: 14) {
            VStack(spacing: 16) {
                if card.kind == .meaning {
                    wordHeader(w)
                    sentenceBox(Text(Self.linked(w.sentence, target: w.form.isEmpty ? w.word : w.form)), speak: w.sentence)
                        .opacity(w.sentence.isEmpty ? 0 : 1)
                } else {
                    Text("想一想：空格裡是哪個英文字？")
                        .font(Theme.rounded(14, .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    // 翻面前不能點（會看到答案）；翻面後每個字都能點
                    sentenceBox(Text(showAnswer ? Self.linked(w.sentence, target: w.form.isEmpty ? w.word : w.form)
                                                : Self.blanked(w.sentence, word: w.form.isEmpty ? w.word : w.form)),
                                speak: showAnswer ? w.sentence : nil)
                    if !w.sentenceZh.isEmpty {
                        Text(w.sentenceZh)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !showAnswer {
                        inputField("打出空格裡的字，按 Return 對答案", text: $clozeInput, focus: $clozeFocused, wrong: false)
                            .onSubmit { revealCloze(w) }
                    } else if let ok = clozeResult {
                        HStack(spacing: 6) {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            Text(ok ? "答對了！" : "你打的是「\(clozeInput)」")
                        }
                        .font(Theme.rounded(15, .bold))
                        .foregroundStyle(ok ? Color.green : Color(red: 1, green: 0.42, blue: 0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if showAnswer { wordHeader(w) }
                }
            }
            .padding(20)
            .glassCard(cornerRadius: 20)

            if showAnswer { answerDetails(w, kind: card.kind) }
            WordLookupCard(lookup: lookup, store: store)
            if card.kind == .meaning || showAnswer {
                Text("點句子裡的單字或同字根的字可以查字典、收藏")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    /// 深色玻璃輸入框（克漏字作答、拼字練習）
    private func inputField(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding, wrong: Bool) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.35)))
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .autocorrectionDisabled()
            .focused(focus)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(wrong ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent), lineWidth: 2))
            .shadow(color: (wrong ? Color.red : Theme.pink).opacity(0.3), radius: 8)
    }

    private func wordHeader(_ w: SavedWord) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(w.word)
                    .font(Theme.rounded(40, .heavy))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.purple.opacity(0.6), radius: 10)
                Button { SpeechService.shared.speak(w.word) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 32))
                .help("發音")
            }
            if !w.phonetic.isEmpty {
                Text("/\(w.phonetic)/").font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func sentenceBox(_ text: Text, speak: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            text.font(.system(size: 16)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let speak {
                Button { SpeechService.shared.speak(speak) } label: {
                    Image(systemName: "speaker.wave.1.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 24))
                .help("整句發音")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 背面：釋義、整句翻譯、字根拆解、同字根家族
    private func answerDetails(_ w: SavedWord, kind: CardKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("中文釋義", systemImage: "text.book.closed.fill", color: Theme.amber)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(w.definition.prefix(5).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let m = w.morph, m.isUseful {
                Divider().overlay(Color.white.opacity(0.15))
                sectionTitle("字根拆解", systemImage: "puzzlepiece.extension.fill", color: Theme.teal)
                MorphChips(morph: m)
                familyView(w, morph: m)
            }

            if !w.sentenceZh.isEmpty, kind == .meaning {  // 克漏字卡正面已經有中文了
                Divider().overlay(Color.white.opacity(0.15))
                Text(w.sentenceZh)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func sectionTitle(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.rounded(12, .bold))
            .foregroundStyle(color)
    }

    /// 同字根家族：先列單字本裡已收藏的（黃色），再列字典裡的同家族字
    @ViewBuilder
    private func familyView(_ w: SavedWord, morph: MorphInfo) -> some View {
        let saved = store.family(of: w)
        let savedSet = Set(saved.map { $0.word.lowercased() })
        let rootExamples = (morph.parts ?? []).filter { $0.type == "root" }.flatMap(\.examples)
        let others = Array(rootExamples.filter { !savedSet.contains($0.lowercased()) }.prefix(6))
        if !saved.isEmpty || !others.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("同字根").font(Theme.rounded(12, .bold)).foregroundStyle(.white.opacity(0.6))
                FlowRow(spacing: 6) {
                    ForEach(saved) { f in
                        Button { lookup.lookup(f.word, sentence: f.sentence, sentenceZh: f.sentenceZh) } label: {
                            Text("★ \(f.word)")
                                .font(Theme.rounded(12, .bold))
                                .foregroundStyle(Theme.amber)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Theme.amber.opacity(0.18), in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("查「\(f.word)」")
                    }
                    ForEach(others, id: \.self) { e in
                        Button { lookup.lookup(e) } label: {
                            Text(e)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Color.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.glassStroke, lineWidth: 1))
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
        VStack(spacing: 8) {
            if let sc = spelling, sc.id == card.id {
                spellingBar(sc.word)
            } else if showAnswer && practice {
                HStack(spacing: 12) {
                    practiceButton(card, .again, title: "再一次", key: "1")
                    practiceButton(card, .good, title: "記得了", key: "2")
                }
            } else if showAnswer {
                HStack(spacing: 10) {
                    ForEach(CardScheduler.Answer.allCases, id: \.rawValue) { a in
                        answerButton(card, a)
                    }
                }
            } else {
                if card.kind == .cloze {
                    // 克漏字卡正面有輸入框，不用空白鍵快捷鍵（會吃掉打字）
                    Button { revealCloze(card.word) } label: { Text("顯示答案") }
                        .buttonStyle(GlowButtonStyle(height: 48))
                    Text("打出答案按 Return 對答案；想不起來就直接按 Return")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                } else {
                    Button { showAnswer = true } label: { Text("顯示答案") }
                        .buttonStyle(GlowButtonStyle(height: 48))
                        .keyboardShortcut(.space, modifiers: [])
                    Text("按空白鍵顯示答案").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    private func answerButton(_ card: ReviewCard, _ a: CardScheduler.Answer) -> some View {
        let key = ["1", "2", "3", "4"][CardScheduler.Answer.allCases.firstIndex(of: a)!]
        return Button { answer(card, a) } label: {
            VStack(spacing: 1) {
                Text(a.title).font(Theme.rounded(15, .bold))
                Text("\(CardScheduler.preview(card.state, answer: a))・\(key)")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.8)
            }
        }
        .buttonStyle(GlowButtonStyle(gradient: Self.gradient(a), glow: Self.color(a), height: 50))
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
    }

    private func practiceButton(_ card: ReviewCard, _ a: CardScheduler.Answer, title: String, key: String) -> some View {
        Button { answer(card, a) } label: {
            VStack(spacing: 1) {
                Text(title).font(Theme.rounded(15, .bold))
                Text(key).font(.system(size: 10, weight: .medium)).opacity(0.8)
            }
        }
        .buttonStyle(GlowButtonStyle(gradient: Self.gradient(a), glow: Self.color(a), height: 50))
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
    }


    /// 克漏字卡翻面：有打字就判斷對錯（原形或原句詞形都算，大小寫不拘）
    private func revealCloze(_ w: SavedWord) {
        let typed = clozeInput.trimmingCharacters(in: .whitespaces).lowercased()
        if typed.isEmpty {
            clozeResult = nil
        } else {
            let accepted = Set([w.word.lowercased(), w.form.lowercased()].filter { !$0.isEmpty })
            clozeResult = accepted.contains(typed)
            if clozeResult == true { SpeechService.shared.speak(w.word) }
        }
        clozeFocused = false
        showAnswer = true
    }

    private func focusClozeIfNeeded() {
        guard queue.first?.kind == .cloze else { return }
        DispatchQueue.main.async { clozeFocused = true }
    }

    private func startPractice(onlyLapsed: Bool) {
        queue = store.practiceCards(onlyLapsed: onlyLapsed)
        practice = true
        reviewed = 0
        showAnswer = false
        spelling = nil
    }

    /// 拼字練習：看著上面的答案把字打出來，打對指定次數才換下一張
    private func spellingBar(_ w: SavedWord) -> some View {
        let need = AppSettings.spellingRepeats
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.fill").foregroundStyle(Theme.pink)
                Text("打一次加強記憶：「\(w.word)」")
                    .font(Theme.rounded(14, .bold))
                Spacer()
                // 進度點：打對幾次
                ForEach(0..<need, id: \.self) { i in
                    Circle().fill(i < spellCount ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.white.opacity(0.18)))
                        .frame(width: 10, height: 10)
                        .shadow(color: i < spellCount ? .green : .clear, radius: 4)
                }
            }
            HStack(spacing: 10) {
                inputField("在這裡打出單字，按 Return", text: $spellInput, focus: $spellFocused, wrong: spellWrong)
                    .onSubmit { checkSpelling(w) }
                    .onChange(of: spellInput) { _, _ in spellWrong = false }
                Button("略過") { finishSpelling() }
                    .buttonStyle(GlassButtonStyle(height: 46))
            }
            Text(spellWrong ? "拼錯了，對照上面再打一次" : "大小寫不拘；打對 \(need) 次就換下一張")
                .font(.system(size: 11))
                .foregroundStyle(spellWrong ? Color(red: 1, green: 0.42, blue: 0.45) : .white.opacity(0.45))
        }
    }

    private func checkSpelling(_ w: SavedWord) {
        let typed = spellInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typed.isEmpty else { return }
        let accepted = Set([w.word.lowercased(), w.form.lowercased()].filter { !$0.isEmpty })
        if accepted.contains(typed) {
            spellCount += 1
            spellInput = ""
            SpeechService.shared.speak(w.word)
            if spellCount >= AppSettings.spellingRepeats {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { finishSpelling() }
            }
        } else {
            spellWrong = true
            NSSound.beep()
        }
    }

    private func answer(_ card: ReviewCard, _ a: CardScheduler.Answer) {
        if !practice { store.answer(card, a) }
        reviewed += 1
        if a == .again, AppSettings.spellingPractice {
            spelling = card
            spellInput = ""
            spellCount = 0
            spellWrong = false
            SpeechService.shared.speak(card.word.word)
            DispatchQueue.main.async { spellFocused = true }
            return
        }
        advance(card, a)
    }

    private func finishSpelling() {
        guard let card = spelling else { return }
        spelling = nil
        spellFocused = false
        advance(card, .again)
    }

    private func delete(_ card: ReviewCard) {
        store.delete(id: card.word.id)
        queue.removeAll { $0.word.id == card.word.id }
        spelling = nil
        showAnswer = false
    }

    private func advance(_ card: ReviewCard, _ a: CardScheduler.Answer) {
        guard queue.first?.id == card.id else { return }
        queue.removeFirst()
        // 忘記的卡片放回這一輪最後面，再考一次
        if a == .again, let w = store.words.first(where: { $0.id == card.word.id }), let st = w.cards[card.kind] {
            queue.append(ReviewCard(word: w, kind: card.kind, state: st))
        }
        showAnswer = false
    }

    // MARK: - 完成

    private var doneView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            // 發光的大圓圈
            ZStack {
                Circle().fill(Theme.accent).frame(width: 120, height: 120)
                    .shadow(color: Theme.pink.opacity(0.7), radius: 30)
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 2).frame(width: 120, height: 120)
                Image(systemName: store.words.isEmpty ? "star.fill" : "checkmark")
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 8)
            Text(store.words.isEmpty ? "單字本還是空的" : practice ? "這輪練習結束！" : "今天的單字卡都複習完了！")
                .font(Theme.rounded(24, .heavy))
            Text(store.words.isEmpty
                 ? "玩遊戲時點英文單字，在字卡上按「☆ 收藏」就會加進來。"
                 : nextDueText)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            if !store.words.isEmpty {
                let all = store.words.reduce(0) { $0 + $1.cards.count }
                let lapsed = store.lapsedCardCount
                VStack(spacing: 10) {
                    Text("想多練幾次？練習不會改變下次複習的日期")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 12) {
                        Button { startPractice(onlyLapsed: true) } label: {
                            Label("只練忘記過的（\(lapsed) 張）", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(height: 46))
                        .disabled(lapsed == 0)
                        .opacity(lapsed == 0 ? 0.4 : 1)
                        Button { startPractice(onlyLapsed: false) } label: {
                            Label("全部再練一輪（\(all) 張）", systemImage: "repeat")
                        }
                        .buttonStyle(GlowButtonStyle(height: 46))
                    }
                    .frame(maxWidth: 440)
                }
                .padding(.top, 14)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
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
                piece.foregroundColor = Theme.amber
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
        b.foregroundColor = Color(red: 1.00, green: 0.45, blue: 0.70)
        a += b
        a += AttributedString(sentence[r.upperBound...])
        return a
    }

    static func gradient(_ a: CardScheduler.Answer) -> LinearGradient {
        let c: [Color]
        switch a {
        case .again: c = [Color(red: 1.0, green: 0.36, blue: 0.42), Color(red: 0.85, green: 0.20, blue: 0.45)]
        case .hard: c = [Color(red: 1.0, green: 0.66, blue: 0.25), Color(red: 0.95, green: 0.42, blue: 0.22)]
        case .good: c = [Theme.blue, Theme.purple]
        case .easy: c = [Color(red: 0.25, green: 0.88, blue: 0.62), Theme.teal]
        }
        return LinearGradient(colors: c, startPoint: .topLeading, endPoint: .bottomTrailing)
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
