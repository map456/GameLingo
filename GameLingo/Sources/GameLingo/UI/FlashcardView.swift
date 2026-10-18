import SwiftUI

/// 單字卡複習（輕鬆版，依「主動回想」設計：每題都先自己想，大部分時候答得出來）。
///
/// 每個收藏的字一張階梯卡，題型依等級變化：
/// - 第 1 層：看英文單字＋遊戲原句，從 4 個中文意思選一個
/// - 第 2 層：克漏字（沒有原句就看中文意思），從 4 個英文字選一個
/// - 第 3 層：克漏字打字，一直顯示首字母與字數（例如 f _ _ _ _ _ _）
/// 答對 2 次升一層、答錯降一層。自動評分：答對＝普通、拼錯一個字母＝困難、答錯＝忘記；
/// 答錯時可以按「其實我會」改判。打單字答錯會讓你再打（每錯一次多露一個字母，第 2、3 次打對算「困難」）；
/// 錯 3 次或按「想不起來」就顯示答案，照著打一次再換題（算答錯）。答錯的字隔幾題後用簡單一層的題型再考一次（不影響排程）。
/// 今天的卡複習完可以再練一輪，練習也不改排程。
///
/// 上方可以選「練習方式」：自動（依等級出題，推薦）、固定選意思／選單字／打單字，或舊版「翻卡自評」
/// （看英文想中文、翻面後自己按忘記／困難／普通／簡單）。固定方式只更新排程，不改等級。
struct FlashcardView: View {
    enum QType: Int { case pickMeaning = 0, pickWord, typeWord, flip }

    enum Mode: String, CaseIterable {
        case auto, pickMeaning, pickWord, typeWord, flip

        var title: String {
            switch self {
            case .auto: return "自動（推薦）"
            case .pickMeaning: return "選意思"
            case .pickWord: return "選單字"
            case .typeWord: return "打單字"
            case .flip: return "翻卡自評"
            }
        }

        var help: String {
            switch self {
            case .auto: return "依熟練度出題：第 1 層選意思 → 第 2 層選單字 → 第 3 層打單字"
            case .pickMeaning: return "看英文和原句，從 4 個中文意思選一個"
            case .pickWord: return "看挖空的原句，從 4 個英文字選一個"
            case .typeWord: return "看挖空的原句打出單字（有首字母和字數提示）"
            case .flip: return "看英文想中文，翻面後自己按忘記／困難／普通／簡單"
            }
        }

        var fixedType: QType? {
            switch self {
            case .auto: return nil
            case .pickMeaning: return .pickMeaning
            case .pickWord: return .pickWord
            case .typeWord: return .typeWord
            case .flip: return .flip
            }
        }
    }
    enum Result { case correct, near, wrong }

    struct Item: Identifiable {
        let id = UUID()
        var card: ReviewCard
        var type: QType
        var retry = false   // 答錯後的再考一次：不寫排程
    }

    @ObservedObject var store: StudyStore
    @ObservedObject var lookup: WordLookup
    let dictionary: DictionaryClient

    @State private var queue: [Item] = []
    @State private var done = 0
    @State private var loaded = false
    @State private var practice = false      // 額外練習：不寫入排程
    @State private var stoppedEarly = false
    @State private var sessionAnswered = 0
    @State private var sessionCorrect = 0
    // 目前這一題
    @State private var options: [String] = []
    @State private var answerIndex = 0
    @State private var picked: Int?
    @State private var result: Result?
    @State private var overridden = false    // 按了「其實我會」
    @State private var typed = ""
    @State private var attempts = 0          // 打單字：已經打錯幾次
    @State private var lastWrong = ""        // 打單字：上一次打錯的內容
    @State private var showTypeAnswer = false // 打單字：已顯示答案，照著打一次
    @FocusState private var typeFocused: Bool
    /// 字典隨機常用字（選擇題的錯誤選項，單字本的字不夠時補）
    @State private var pool: [DictionaryClient.RandomWord] = []
    // 答錯後照著打（設定可開）
    @State private var spelling = false
    @State private var spellInput = ""
    @State private var spellCount = 0
    @State private var spellWrong = false
    @FocusState private var spellFocused: Bool
    @State private var confirmDelete = false
    @State private var flipped = false       // 翻卡自評：已翻面
    @AppStorage("reviewMode") private var modeRaw = Mode.auto.rawValue
    private var mode: Mode { Mode(rawValue: modeRaw) ?? .auto }

    private var current: Item? { queue.first }
    private var answered: Bool { result != nil }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
            if let item = current {
                // 不用捲動：視窗高度跟著內容走（StudyWindows 依 SwiftUI 算出的理想高度調整視窗）
                cardView(item)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    // 作答後原句的單字是連結（gamelingo://word/…），點了在下方查字典
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "gamelingo", let w = url.pathComponents.dropFirst().first {
                            lookup.lookup(w, sentence: item.card.word.sentence, sentenceZh: item.card.word.sentenceZh)
                        }
                        return .handled
                    })
                answerBar(item)
            } else if loaded {
                doneView
            }
        }
        .frame(width: 600)
        .frame(minHeight: 480, alignment: .top)
        .background(ThemeBackground())
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .onAppear(perform: start)
        .onChange(of: queue.first?.id) { _, _ in prepare() }
        .onChange(of: modeRaw) { _, _ in applyMode() }
    }

    private func start() {
        queue = store.dueCards().map(makeItem)
        loaded = true
        lookup.close()
        if queue.isEmpty, ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_PRACTICE"] == "1" {
            startPractice(onlyLapsed: false)  // 測試用：沒有到期卡時直接進練習
        }
        prepare()
        Task {
            pool = await dictionary.randomWords(40)
            if !answered { buildOptions() }  // 單字本的字不夠四個選項時，字典回來後補齊
        }
        // 測試用：GAMELINGO_DEBUG_REVIEW=1 時 2 秒後自動作答；GAMELINGO_DEBUG_LOOKUP=字 時 3 秒後查字
        let env = ProcessInfo.processInfo.environment
        if env["GAMELINGO_DEBUG_REVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if current?.type == .typeWord { typed = "x"; submitTyped() } else if current?.type == .flip { flipped = true } else if !options.isEmpty { choose(0) }
            }
        }
        if let w = env["GAMELINGO_DEBUG_LOOKUP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lookup.lookup(w) }
        }
    }

    private func makeItem(_ card: ReviewCard) -> Item {
        Item(card: card, type: mode.fixedType ?? Self.type(forLevel: card.word.level))
    }

    /// 換練習方式：還沒作答的題目都改用新方式出題（已作答的這一題不動）
    private func applyMode() {
        let keepFirst = answered || flipped || spelling
        queue = queue.enumerated().map { i, item in
            if i == 0 && keepFirst { return item }
            var new = makeItem(item.card)
            if item.retry, mode == .auto { new.type = item.type }
            new.retry = item.retry
            return new
        }
    }

    static func type(forLevel level: Int) -> QType {
        QType(rawValue: max(0, min(2, level - 1))) ?? .pickMeaning
    }

    // MARK: - 上方進度

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(practice ? "額外練習" : "單字卡複習").font(Theme.rounded(24, .heavy))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let item = current {
                    TagPill(text: tagText(item), color: Self.tagColor(item.type))
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 30))
                    .help("把「\(item.card.word.word)」從單字本刪除")
                    .confirmationDialog("要刪除「\(item.card.word.word)」嗎？", isPresented: $confirmDelete) {
                        Button("刪除", role: .destructive) { delete(item) }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("會從單字本移除，之後不再出題。之後可以在遊戲裡重新收藏。")
                    }
                    Button { stopForToday() } label: {
                        Image(systemName: "moon.zzz.fill")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 30))
                    .help("今天先到這裡（剩下的明天再練，不扣分）")
                }
            }
            if !queue.isEmpty {
                GradientProgressBar(value: Double(done) / Double(max(1, done + queue.count)))
            }
            modeBar
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// 練習方式選擇列
    private var modeBar: some View {
        HStack(spacing: 6) {
            Text("練習方式").font(Theme.rounded(11, .bold)).foregroundStyle(.white.opacity(0.5))
            ForEach(Mode.allCases, id: \.rawValue) { m in
                let on = m == mode
                Button { modeRaw = m.rawValue } label: {
                    Text(m.title)
                        .font(Theme.rounded(12, on ? .bold : .medium))
                        .foregroundStyle(.white.opacity(on ? 1 : 0.7))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? Color.white.opacity(0.25) : Theme.glassStroke, lineWidth: 1))
                        .shadow(color: on ? Theme.pink.opacity(0.45) : .clear, radius: 5)
                }
                .buttonStyle(.plain)
                .help(m.help)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let score = sessionAnswered > 0 ? "・答對 \(sessionCorrect)/\(sessionAnswered)" : ""
        if practice { return "不影響下次複習的日期\(score)" }
        return "剩 \(queue.count) 題\(score)"
    }

    private func tagText(_ item: Item) -> String {
        if item.retry { return "再試一次" }
        if mode != .auto { return "第 \(item.card.word.level) 層・" + (mode == .flip ? "翻卡" : mode.title) }
        switch item.type {
        case .pickMeaning: return "第 1 層・選意思"
        case .pickWord: return "第 2 層・選單字"
        case .typeWord: return "第 3 層・打單字"
        case .flip: return "翻卡自評"
        }
    }

    static func tagColor(_ t: QType) -> Color {
        switch t {
        case .pickMeaning: return Theme.teal
        case .pickWord: return Theme.blue
        case .typeWord: return Theme.pink
        case .flip: return Theme.purple
        }
    }

    // MARK: - 題目

    @ViewBuilder
    private func cardView(_ item: Item) -> some View {
        let w = item.card.word
        VStack(spacing: 14) {
            VStack(spacing: 16) {
                question(item)
                if answered && item.type != .flip { resultBanner(item) }
            }
            .padding(20)
            .glassCard(cornerRadius: 20)

            if answered || flipped {
                answerDetails(w, showSentenceZh: item.type == .pickMeaning || item.type == .flip)
                WordLookupCard(lookup: lookup, store: store)
                Text("點句子裡的單字或同字根的字可以查字典、收藏")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func question(_ item: Item) -> some View {
        let w = item.card.word
        let target = Self.target(w)
        switch item.type {
        case .pickMeaning:
            prompt("這個字是什麼意思？")
            wordHeader(w)
            if !w.sentence.isEmpty { sentenceBox(sentenceText(item, hint: nil), speak: w.sentence) }
            optionList()

        case .pickWord:
            if w.hasClozeSentence {
                prompt("空格裡是哪個字？")
                sentenceBox(sentenceText(item, hint: nil), speak: answered ? w.sentence : nil)
                zhLine(w.sentenceZh)
            } else {
                prompt("哪個英文字是這個意思？")
                meaningBig(w)
            }
            optionList()
            if answered { wordHeader(w) }

        case .flip:
            prompt(flipped ? "記得嗎？依記得的程度作答" : "想一想：這個字是什麼意思？")
            wordHeader(w)
            if !w.sentence.isEmpty { sentenceBox(sentenceText(item, hint: nil), speak: w.sentence) }

        case .typeWord:
            let hint = Self.hintPattern(target, shown: 1 + attempts)
            if w.hasClozeSentence {
                prompt("打出空格裡的字")
                sentenceBox(sentenceText(item, hint: hint), speak: answered ? w.sentence : nil)
                zhLine(w.sentenceZh)
            } else {
                prompt("打出這個意思的英文字")
                meaningBig(w)
            }
            if !answered {
                VStack(spacing: 6) {
                    if showTypeAnswer {
                        Text("答案是「\(target)」，照著打一次記起來")
                            .font(Theme.rounded(16, .bold))
                            .foregroundStyle(Theme.amber)
                        Text(target)
                            .font(.system(size: 30, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    } else {
                        if attempts > 0 {
                            Text("「\(lastWrong)」不對，再試一次（多給你一個字母）")
                                .font(Theme.rounded(14, .bold))
                                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.45))
                        }
                        Text(hint)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.pink)
                        Text("提示：首字母 \(String(target.prefix(1)))，共 \(target.filter(\.isLetter).count) 個字母"
                             + (attempts > 0 ? "・還可以試 \(3 - attempts) 次" : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                inputField(showTypeAnswer ? "照著上面打一次，按 Return" : "在這裡打字，按 Return 送出",
                           text: $typed, focus: $typeFocused, wrong: attempts > 0 && !showTypeAnswer)
                    .onSubmit(submitTyped)
            } else {
                wordHeader(w)
            }
        }
    }

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(Theme.rounded(14, .semibold))
            .foregroundStyle(.white.opacity(0.7))
    }

    @ViewBuilder
    private func zhLine(_ zh: String) -> some View {
        if !zh.isEmpty {
            Text(zh)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 沒有原句時，題目直接用中文意思
    private func meaningBig(_ w: SavedWord) -> some View {
        Text(Self.shortMeaning(w.definition))
            .font(Theme.rounded(22, .bold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 原句：作答前不能點（會看到答案），該字挖空或加底線；作答後每個字都能點
    private func sentenceText(_ item: Item, hint: String?) -> Text {
        let w = item.card.word
        let target = w.form.isEmpty ? w.word : w.form
        if answered || flipped { return Text(Self.linked(w.sentence, target: target)) }
        if item.type == .pickMeaning || item.type == .flip { return Text(Self.highlighted(w.sentence, word: target)) }
        return Text(Self.blanked(w.sentence, word: target, hint: hint))
    }

    /// 四選一（按 1～4 或點選）
    private func optionList() -> some View {
        VStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, text in
                optionButton(i, text)
            }
        }
    }

    private func optionButton(_ i: Int, _ text: String) -> some View {
        let red = Color(red: 1, green: 0.42, blue: 0.45)
        let isAnswer = i == answerIndex
        let isPicked = i == picked
        let stroke: Color = answered && isAnswer ? .green : (answered && isPicked ? red : Theme.glassStroke)
        let fill: Color = answered && isAnswer ? Color.green.opacity(0.22)
            : (answered && isPicked ? Color.red.opacity(0.22) : Color.white.opacity(0.07))
        return Button { choose(i) } label: {
            HStack(spacing: 12) {
                Text("\(i + 1)")
                    .font(Theme.rounded(13, .heavy))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.12), in: Circle())
                Text(text)
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if answered && isAnswer {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if answered && isPicked {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(stroke, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!answered)   // 不用 disabled：作答後選項不要變暗，綠色答案才看得清楚
        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
    }

    /// 作答結果
    private func resultBanner(_ item: Item) -> some View {
        let target = item.type == .pickWord ? item.card.word.word : Self.target(item.card.word)
        let red = Color(red: 1, green: 0.42, blue: 0.45)
        let icon: String
        let text: String
        let color: Color
        if overridden {
            (icon, text, color) = ("checkmark.circle.fill", "好，這題算你會", .green)
        } else if result == .correct {
            (icon, text, color) = ("checkmark.circle.fill", "答對了！", .green)
        } else if result == .near, attempts > 0 {
            (icon, text, color) = ("checkmark.circle", "第 \(attempts + 1) 次打對了！", Theme.amber)
        } else if result == .near {
            (icon, text, color) = ("checkmark.circle", "差一點！你打「\(typed)」，正確是「\(target)」", Theme.amber)
        } else if item.type == .typeWord {
            (icon, text, color) = ("xmark.circle.fill", "記住了！這個字等一下會再考一次", red)
        } else {
            (icon, text, color) = ("xmark.circle.fill", "沒關係，記住正確答案，等一下會再考一次", red)
        }
        return HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Theme.rounded(15, .bold))
        .foregroundStyle(color)
    }

    /// 深色玻璃輸入框（第 3 層作答、照著打練習）
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

    /// 作答後：釋義、字根拆解、同字根家族、整句翻譯
    private func answerDetails(_ w: SavedWord, showSentenceZh: Bool) -> some View {
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

            if !w.sentenceZh.isEmpty, showSentenceZh {  // 克漏字題目上已經有中文了
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

    // MARK: - 下方按鈕

    @ViewBuilder
    private func answerBar(_ item: Item) -> some View {
        VStack(spacing: 8) {
            if spelling {
                spellingBar(item.card.word)
            } else if item.type == .flip {
                if flipped {
                    HStack(spacing: 10) {
                        ForEach(Array(CardScheduler.Answer.allCases.enumerated()), id: \.offset) { i, a in
                            gradeButton(item, a, key: "\(i + 1)")
                        }
                    }
                    Text("按 1～4 作答").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                } else {
                    Button { flipped = true } label: { Text("顯示答案") }
                        .buttonStyle(GlowButtonStyle(height: 48))
                        .keyboardShortcut(.space, modifiers: [])
                    Text("按空白鍵顯示答案").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            } else if answered {
                HStack(spacing: 12) {
                    if result != .correct, !overridden, !item.retry, !practice {
                        Button { overridden = true } label: { Text("其實我會") }
                            .buttonStyle(GlassButtonStyle(height: 48))
                            .help("按錯或打錯字時用：這題改判答對")
                    }
                    Button(action: next) { Text("下一題") }
                        .buttonStyle(GlowButtonStyle(height: 48))
                        .keyboardShortcut(.defaultAction)
                }
                Text("按 Return 下一題").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            } else if item.type == .typeWord {
                HStack(spacing: 12) {
                    if showTypeAnswer {
                        Button { result = .wrong; typeFocused = false } label: { Text("略過") }
                            .buttonStyle(GlassButtonStyle(height: 48))
                    } else {
                        Button(action: giveUpTyping) { Text("想不起來") }
                            .buttonStyle(GlassButtonStyle(height: 48))
                    }
                    Button(action: submitTyped) { Text("送出") }
                        .buttonStyle(GlowButtonStyle(height: 48))
                }
                Text(showTypeAnswer ? "照著打完就換下一題" : "大小寫不拘；只錯一個字母也算對；打錯可以再試")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            } else {
                Button(action: reveal) { Text("想不起來，看答案") }
                    .buttonStyle(GlassButtonStyle(height: 44))
                Text("按 1～4 選答案").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 22)
    }

    /// 翻卡自評的作答鈕：忘記／困難／普通／簡單，下方顯示下次多久後複習
    private func gradeButton(_ item: Item, _ a: CardScheduler.Answer, key: String) -> some View {
        Button { gradeFlip(item, a) } label: {
            VStack(spacing: 1) {
                Text(a.title).font(Theme.rounded(15, .bold))
                Text("\(practice || item.retry ? "練習" : CardScheduler.preview(item.card.state, answer: a))・\(key)")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.8)
            }
        }
        .buttonStyle(GlowButtonStyle(gradient: Self.gradient(a), glow: Self.color(a), height: 50))
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
    }

    private func gradeFlip(_ item: Item, _ a: CardScheduler.Answer) {
        guard flipped, current?.id == item.id else { return }
        let correct = a != .again
        sessionAnswered += 1
        if correct { sessionCorrect += 1 }
        if practice || item.retry {
            store.logPractice(wordID: item.card.word.id, correct: correct)
        } else {
            store.answer(item.card, a, correct: correct, updateLevel: false)
        }
        if !correct, AppSettings.spellingPractice {
            result = .wrong
            spelling = true
            spellInput = ""
            spellCount = 0
            spellWrong = false
            DispatchQueue.main.async { spellFocused = true }
            return
        }
        advance(item, correct: correct)
    }

    // MARK: - 作答流程

    /// 換題時重設狀態、準備選項、輸入框取得焦點
    private func prepare() {
        picked = nil
        result = nil
        overridden = false
        typed = ""
        attempts = 0
        lastWrong = ""
        showTypeAnswer = false
        spelling = false
        flipped = false
        lookup.close()
        buildOptions()
        if current?.type == .typeWord {
            DispatchQueue.main.async { typeFocused = true }
        }
    }

    /// 選擇題選項：錯誤選項先從單字本的其他字挑，不夠再用字典的隨機常用字
    private func buildOptions() {
        guard let item = current, item.type == .pickMeaning || item.type == .pickWord else { options = []; return }
        let w = item.card.word
        let others = store.words.filter { $0.id != w.id }.shuffled()
        let correct: String
        let candidates: [String]
        if item.type == .pickMeaning {
            correct = Self.shortMeaning(w.definition)
            candidates = others.map { Self.shortMeaning($0.definition) } + pool.map { Self.shortMeaning($0.translation) }
        } else {
            correct = w.word.lowercased()
            candidates = others.map { $0.word.lowercased() } + pool.map { $0.word.lowercased() }
        }
        var wrong: [String] = []
        for o in candidates where wrong.count < 3 && !o.isEmpty && o != correct && !wrong.contains(o) {
            wrong.append(o)
        }
        let all = (wrong + [correct]).shuffled()
        options = all
        answerIndex = all.firstIndex(of: correct) ?? 0
    }

    private func choose(_ i: Int) {
        guard !answered, i < options.count else { return }
        picked = i
        result = i == answerIndex ? .correct : .wrong
        if result == .correct, let w = current?.card.word { SpeechService.shared.speak(w.word) }
    }

    /// 選擇題「想不起來」：直接看答案，算答錯
    private func reveal() {
        guard !answered else { return }
        picked = nil
        result = .wrong
    }

    /// 打單字送出：第一次打對＝答對；打錯就再試（最多 3 次），第 2、3 次打對算「困難」；
    /// 顯示答案後要照著打對才換題（算答錯）
    private func submitTyped() {
        guard let item = current, !answered else { return }
        let w = item.card.word
        let t = Self.normalize(typed)
        guard !t.isEmpty else { return }
        let accepted = [Self.target(w), w.word].map(Self.normalize)
        let exact = accepted.contains(t)
        let typo = !exact && accepted.contains(where: { $0.count >= 4 && Self.distance(t, $0) == 1 })
        if showTypeAnswer {
            if exact || typo {
                result = .wrong
                typeFocused = false
                SpeechService.shared.speak(w.word)
            } else {
                NSSound.beep()
            }
            return
        }
        if exact || typo {
            result = exact && attempts == 0 ? .correct : .near
            typeFocused = false
            SpeechService.shared.speak(w.word)
            return
        }
        attempts += 1
        lastWrong = typed.trimmingCharacters(in: .whitespaces)
        typed = ""
        NSSound.beep()
        if attempts >= 3 { showTypeAnswer = true }
        DispatchQueue.main.async { typeFocused = true }
    }

    /// 打單字「想不起來」：顯示答案，照著打一次
    private func giveUpTyping() {
        guard !answered else { return }
        showTypeAnswer = true
        typed = ""
        DispatchQueue.main.async { typeFocused = true }
    }

    /// 下一題：寫入評分（正式複習才動排程），答錯的排在幾題後用簡單一層再考
    private func next() {
        guard let item = current, let result else { return }
        let correct = overridden || result != .wrong
        sessionAnswered += 1
        if correct { sessionCorrect += 1 }
        if practice || item.retry {
            store.logPractice(wordID: item.card.word.id, correct: correct)
        } else {
            let grade: CardScheduler.Answer = overridden || result == .correct ? .good : (result == .near ? .hard : .again)
            store.answer(item.card, grade, correct: correct, updateLevel: mode == .auto)
        }
        // 答錯後照著打（設定可開）
        if !correct, AppSettings.spellingPractice {
            spelling = true
            spellInput = ""
            spellCount = 0
            spellWrong = false
            DispatchQueue.main.async { spellFocused = true }
            return
        }
        advance(item, correct: correct)
    }

    private func advance(_ item: Item, correct: Bool) {
        guard queue.first?.id == item.id else { return }
        queue.removeFirst()
        done += 1
        // 答錯：隔 3 題後再考一次（不影響排程）。自動模式用簡單一層的題型，固定方式維持同一種
        if !correct, !item.retry {
            var card = item.card
            if let fresh = store.words.first(where: { $0.id == card.word.id }) { card.word = fresh }
            let type = mode == .auto ? (QType(rawValue: max(0, item.type.rawValue - 1)) ?? .pickMeaning) : item.type
            queue.insert(Item(card: card, type: type, retry: true), at: min(3, queue.count))
        }
    }

    private func delete(_ item: Item) {
        store.delete(id: item.card.word.id)
        queue.removeAll { $0.card.word.id == item.card.word.id }
    }

    private func stopForToday() {
        stoppedEarly = true
        queue = []
    }

    private func startPractice(onlyLapsed: Bool) {
        queue = store.practiceCards(onlyLapsed: onlyLapsed).map(makeItem)
        practice = true
        stoppedEarly = false
        done = 0
    }

    // MARK: - 答錯後照著打

    private func spellingBar(_ w: SavedWord) -> some View {
        let need = AppSettings.spellingRepeats
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.fill").foregroundStyle(Theme.pink)
                Text("照著打一次：「\(w.word)」")
                    .font(Theme.rounded(14, .bold))
                Spacer()
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
            Text(spellWrong ? "拼錯了，對照上面再打一次" : "打對 \(need) 次就換下一題（設定裡可以關掉）")
                .font(.system(size: 11))
                .foregroundStyle(spellWrong ? Color(red: 1, green: 0.42, blue: 0.45) : .white.opacity(0.45))
        }
    }

    private func checkSpelling(_ w: SavedWord) {
        let t = Self.normalize(spellInput)
        guard !t.isEmpty else { return }
        if [w.word, w.form].map(Self.normalize).contains(t) {
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

    private func finishSpelling() {
        guard spelling, let item = current else { return }
        spelling = false
        spellFocused = false
        advance(item, correct: false)
    }

    // MARK: - 完成

    private var doneView: some View {
        let stats = store.todayStats()
        let streak = store.streakDays()
        return VStack(spacing: 14) {
            Spacer(minLength: 10)
            ZStack {
                Circle().fill(Theme.accent).frame(width: 120, height: 120)
                    .shadow(color: Theme.pink.opacity(0.7), radius: 30)
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 2).frame(width: 120, height: 120)
                Image(systemName: store.words.isEmpty ? "star.fill" : (stoppedEarly ? "moon.zzz.fill" : "checkmark"))
                    .font(.system(size: 50, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 8)
            Text(doneTitle).font(Theme.rounded(24, .heavy))
            Text(doneSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if stats.answered > 0 || streak > 0 {
                HStack(spacing: 12) {
                    statTile("\(stats.answered > 0 ? stats.correct * 100 / stats.answered : 0)%", "今天答對率")
                    statTile("\(stats.answered)", "今天作答")
                    statTile("\(streak) 天", "連續複習")
                }
                .frame(maxWidth: 440)
                .padding(.top, 6)
            }

            if store.learnedCount > 0 {
                let lapsed = store.lapsedCardCount
                VStack(spacing: 10) {
                    Text("想多練幾次？練習不會改變下次複習的日期")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 12) {
                        Button { startPractice(onlyLapsed: true) } label: {
                            Label("只練忘記過的（\(lapsed) 個）", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(GlassButtonStyle(height: 46))
                        .disabled(lapsed == 0)
                        .opacity(lapsed == 0 ? 0.4 : 1)
                        Button { startPractice(onlyLapsed: false) } label: {
                            Label("全部再練一輪（\(store.learnedCount) 個）", systemImage: "repeat")
                        }
                        .buttonStyle(GlowButtonStyle(height: 46))
                    }
                    .frame(maxWidth: 440)
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
    }

    private var doneTitle: String {
        if store.words.isEmpty { return "單字本還是空的" }
        if stoppedEarly { return "今天先到這裡，辛苦了！" }
        return practice ? "這輪練習結束！" : "今天的單字卡都複習完了！"
    }

    private var doneSubtitle: String {
        if store.words.isEmpty { return "玩遊戲時點英文單字，在字卡上按「☆ 收藏」就會加進來。" }
        var parts: [String] = []
        if stoppedEarly { parts.append("剩下的明天再練，不會扣分。") }
        let waiting = store.waitingNewWords
        if waiting > 0 { parts.append("還有 \(waiting) 個新字排隊中，每天最多學 \(AppSettings.newWordsPerDay) 個。") }
        if let next = store.words.filter({ $0.firstReview != nil }).map(\.nextDue).min() {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_TW")
            f.dateFormat = "M 月 d 日"
            parts.append("下一次複習在 \(f.string(from: max(next, Date())))。")
        }
        return parts.joined(separator: "\n")
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Theme.rounded(22, .heavy))
            Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 14)
    }

    // MARK: - 工具

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
        case .good: return Theme.blue
        case .easy: return .green
        }
    }

    /// 題目要的字：原句裡出現的樣子（有原句時），否則原形
    static func target(_ w: SavedWord) -> String {
        guard w.hasClozeSentence else { return w.word.lowercased() }
        let form = w.form.isEmpty ? w.word : w.form
        if let r = w.sentence.range(of: form, options: .caseInsensitive) { return String(w.sentence[r]).lowercased() }
        return form.lowercased()
    }

    /// 前幾個字母＋每個字母一條底線，例如 f _ _ _ _ _ _（撇號、連字號照原樣）；打錯一次多露一個字母
    static func hintPattern(_ word: String, shown: Int = 1) -> String {
        let n = min(shown, max(1, word.count - 1))   // 至少留一個字母要自己打
        return word.enumerated().map { i, c in
            i < n || !c.isLetter ? String(c) : "_"
        }.joined(separator: " ")
    }

    /// 比對用：小寫、去前後空白、彎引號換成直引號
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    /// 兩個字差幾個字母（Levenshtein 距離）
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// 選項用的簡短中文意思：第一個有詞性的釋義，最多 3 個意思，例如「vt. 獲得、達到」
    static func shortMeaning(_ lines: [String]) -> String {
        guard let line = lines.first(where: { !$0.hasPrefix("[") }) ?? lines.first else { return "" }
        var pos = ""
        var body = line.trimmingCharacters(in: .whitespaces)
        if let m = body.range(of: #"^[a-z]+\.\s*"#, options: .regularExpression) {
            pos = String(body[m]).trimmingCharacters(in: .whitespaces) + " "
            body = String(body[m.upperBound...])
        }
        let senses = body.split(whereSeparator: { ",，;；、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pos + senses.prefix(3).joined(separator: "、")
    }

    /// 原句裡把該字加底線、粗體（單字本也會用）
    static func highlighted(_ sentence: String, word: String) -> AttributedString {
        var a = AttributedString(sentence)
        if let r = a.range(of: word, options: [.caseInsensitive]) {
            a[r].underlineStyle = .single
            a[r].font = .system(size: 16, weight: .bold)
            a[r].foregroundColor = Theme.amber
        }
        return a
    }

    /// 原句每個字都做成連結（點了查字典），目標字加金色底線
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
                piece.font = .system(size: 16, weight: .bold)
                piece.foregroundColor = Theme.amber
            }
            out += piece
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        return out
    }

    /// 克漏字：把該字換成空格（選擇題）或提示（打字題，例如 f _ _ _ _ _ _）
    static func blanked(_ sentence: String, word: String, hint: String?) -> AttributedString {
        guard let r = sentence.range(of: word, options: .caseInsensitive) else { return AttributedString(sentence) }
        var a = AttributedString(sentence[..<r.lowerBound])
        var b = AttributedString(hint ?? "＿＿＿＿")
        b.font = .system(size: 16, weight: .bold, design: .monospaced)
        b.foregroundColor = Color(red: 1.00, green: 0.45, blue: 0.70)
        a += b
        a += AttributedString(sentence[r.upperBound...])
        return a
    }
}
