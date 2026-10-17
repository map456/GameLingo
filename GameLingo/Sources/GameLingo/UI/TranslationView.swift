import SwiftUI

/// 浮動視窗內容：
/// 上方狀態列 → 中間是一句一句往下累積的色塊（英文可點單字、中文）→ 下方是點字查詢的字卡（可收藏）。
struct TranslationView: View {
    struct Actions {
        var retranslate: () -> Void
        var beginEdit: () -> Void
        var submitEdit: () -> Void
        var cancelEdit: () -> Void
        var hide: () -> Void
        var lookup: (String, OverlayModel.Entry?) -> Void
        var closeWord: () -> Void
        var speak: (String) -> Void
        var clear: () -> Void
        var toggleSave: () -> Void
        var openReview: () -> Void
        var explain: (UUID) -> Void
        var openSettings: () -> Void
        var closeExplanation: (UUID) -> Void
    }

    @ObservedObject var model: OverlayModel
    @ObservedObject var store: StudyStore
    let actions: Actions
    @AppStorage(AppSettings.Key.chineseFontSize) private var zhSize = 19.0
    @AppStorage(AppSettings.Key.englishFontSize) private var enSize = 15.0

    // 配色（共用 Theme）
    static let savedHighlight = Color(red: 1.0, green: 0.82, blue: 0.25).opacity(0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.editing { editor }
            history
            if model.word != nil || model.wordLoading != nil {
                wordCard
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ThemeBackground(opacity: 0.88))
        .environment(\.colorScheme, .dark)
        // 英文單字是連結（gamelingo://word/…?e=句子id），點了就查字典，不開瀏覽器
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "gamelingo", let w = url.pathComponents.dropFirst().first {
                let eid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "e" }?.value
                actions.lookup(w, model.entries.first { $0.id.uuidString == eid })
            }
            return .handled
        })
    }

    // MARK: - 狀態列

    private var header: some View {
        HStack(spacing: 8) {
            // App 名稱＋狀態
            ZStack {
                Circle().fill(Theme.accent).frame(width: 22, height: 22)
                    .shadow(color: Theme.pink.opacity(0.6), radius: 6)
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.5).tint(.white)
                } else {
                    Image(systemName: "character.bubble.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("GameLingo").font(Theme.rounded(13, .bold)).foregroundStyle(.white)
                Text(model.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.status)
            }
            if model.auto {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                        .shadow(color: .green, radius: 3)
                    Text("自動").font(Theme.rounded(10, .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.green.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.green.opacity(0.5), lineWidth: 1))
                .help("自動翻譯開啟中（⌃⌥A 切換）")
            }
            Spacer(minLength: 4)
            if store.dueCount > 0 {
                Button(action: actions.openReview) {
                    Label("複習 \(store.dueCount)", systemImage: "rectangle.stack.fill")
                        .font(Theme.rounded(11, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.pink.opacity(0.5), radius: 5)
                }
                .buttonStyle(.plain)
                .help("今天有 \(store.dueCount) 張單字卡要複習，點這裡開始")
            }
            iconButton("pencil", help: "修正最後一句的原文後重新翻譯", action: actions.beginEdit)
                .disabled(model.english.isEmpty || model.editing)
            iconButton("arrow.clockwise", help: "重新擷取並翻譯（⌃⌥R）", action: actions.retranslate)
            iconButton("trash", help: "清空清單", action: actions.clear)
                .disabled(model.entries.isEmpty)
            iconButton("gearshape.fill", help: "設定", action: actions.openSettings)
            iconButton("xmark", help: "隱藏（⌃⌥H 再叫出來）", action: actions.hide)
        }
    }

    // MARK: - 累積的翻譯清單

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.entries.isEmpty {
                        emptyState
                    }
                    ForEach(model.entries) { entry in
                        entryView(entry, isLast: entry.id == model.entries.last?.id)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")  // 捲到這裡＝真正的最底部
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .onChange(of: model.entries.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.entries.last?.chinese) { _, _ in
                // 譯文一邊長一邊捲；等這一輪排版完成再捲，避免最後一行被切掉
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
                .shadow(color: Theme.pink.opacity(0.5), radius: 8)
            Text("開始玩吧！").font(Theme.rounded(16, .bold)).foregroundStyle(.white)
            Text("對話會一句一句翻譯在這裡。\n點英文單字可以查字典、收藏到單字本。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassCard()
    }

    /// 一句一張玻璃卡：上面英文（可點單字）、下面中文；最新一句用漸層外框發光
    private func entryView(_ entry: OverlayModel.Entry, isLast: Bool) -> some View {
        let lit = entry.explanation != nil || entry.explaining
        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.linkedEnglish(entry.english, entryID: entry.id, saved: store.savedForms))
                    .font(.system(size: isLast ? enSize : enSize - 2))
                    .foregroundStyle(.white.opacity(isLast ? 0.78 : 0.55))
                    .tint(.white.opacity(isLast ? 0.78 : 0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { actions.speak(entry.english) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 20))
                .help("整句發音")
                Button { actions.explain(entry.id) } label: {
                    Image(systemName: lit ? "lightbulb.fill" : "lightbulb")
                        .foregroundStyle(lit ? Theme.amber : .white.opacity(0.75))
                }
                .buttonStyle(CircleIconButtonStyle(size: 20))
                .disabled(entry.explaining || entry.chinese.isEmpty)
                .help("語境解說：請模型解釋這句的方言、文法、用字（約 10～20 秒）")
            }

            Text(entry.chinese.isEmpty ? "…" : entry.chinese)
                .font(.system(size: isLast ? zhSize : zhSize - 4, weight: isLast ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isLast ? 1 : 0.7))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if lit {
                explanationView(entry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)

        return Group {
            if isLast {
                card.glowCard(cornerRadius: 14)
            } else {
                card.glassCard(cornerRadius: 14)
            }
        }
    }

    /// 語境解說（琥珀色玻璃）：產生中顯示進度與已產生的部分
    private func explanationView(_ entry: OverlayModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 10)).foregroundStyle(Theme.amber)
                Text("語境解說").font(Theme.rounded(11, .bold)).foregroundStyle(Theme.amber)
                if entry.explaining {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("產生中，約 10～20 秒…").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button { actions.closeExplanation(entry.id) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(CircleIconButtonStyle(size: 18))
                .help("收起解說")
            }
            if let text = entry.explanation, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 10, fill: Theme.amber.opacity(0.10), stroke: Theme.amber.opacity(0.35))
        .padding(.top, 2)
    }

    /// 把英文句子的每個單字做成連結（點了查字典）；已收藏的字加上黃色底色
    static func linkedEnglish(_ text: String, entryID: UUID, saved: Set<String>) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z']*")
        var cursor = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            }
            let word = ns.substring(with: m.range)
            var piece = AttributedString(word)
            if let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                piece.link = URL(string: "gamelingo://word/\(encoded)?e=\(entryID.uuidString)")
            }
            piece.underlineStyle = .none
            let key = word.lowercased()
            if saved.contains(key) || saved.contains(key.trimmingCharacters(in: CharacterSet(charactersIn: "'"))) {
                piece.backgroundColor = savedHighlight
            }
            out += piece
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out += AttributedString(ns.substring(from: cursor))
        }
        return out
    }

    // MARK: - 字卡

    private var wordCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let loading = model.wordLoading, model.word == nil {
                HStack {
                    Text("查詢「\(loading)」…").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    closeWordButton
                }
            } else if let info = model.word {
                if info.found {
                    let head = info.lemma?.word ?? info.word ?? info.query ?? ""
                    let saved = store.isSaved(head)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(info.word ?? info.query ?? "").font(Theme.rounded(19, .bold)).foregroundStyle(.white)
                        if let p = info.phonetic, !p.isEmpty {
                            Text("/\(p)/").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                        }
                        Button { actions.speak(info.word ?? info.query ?? "") } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .buttonStyle(CircleIconButtonStyle(size: 22))
                        .help("發音")
                        Spacer()
                        Button(action: actions.toggleSave) {
                            Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
                                .font(Theme.rounded(12, .bold))
                                .foregroundStyle(saved ? Theme.amber : .white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(saved ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(Theme.accent), in: Capsule())
                                .shadow(color: saved ? .clear : Theme.pink.opacity(0.5), radius: 5)
                        }
                        .buttonStyle(.plain)
                        .help(saved ? "從單字本移除" : "收藏到單字本（之後用單字卡複習）")
                        closeWordButton
                    }
                    if let m = model.wordMorph, m.isUseful {
                        MorphChips(morph: m, compact: true).padding(.vertical, 2)
                    }
                    definitionLines(info.translation ?? [])
                    if let lemma = info.lemma {
                        Text("原形 \(lemma.word)\(lemma.phonetic.isEmpty ? "" : "  /\(lemma.phonetic)/")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        definitionLines(lemma.translation)
                    }
                } else {
                    HStack {
                        Text(info.error ?? "字典裡查不到「\(info.query ?? "")」（可能是口音拼寫或專有名詞）")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        closeWordButton
                    }
                }
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard(cornerRadius: 14, gradient: Theme.accentCool, glow: Theme.teal)
    }

    private func definitionLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.prefix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var closeWordButton: some View {
        iconButton("xmark.circle.fill", help: "關閉字卡", action: actions.closeWord)
    }

    // MARK: - 修正原文

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $model.editText)
                .font(.system(size: 14))
                .frame(minHeight: 54, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .glassCard(cornerRadius: 10)
            HStack {
                Text("修正最後一句的原文，按 ⌘↩ 翻譯").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: actions.cancelEdit)
                    .keyboardShortcut(.cancelAction)
                Button("翻譯", action: actions.submitEdit)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(CircleIconButtonStyle(size: 24))
        .help(help)
    }
}
