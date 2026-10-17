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

    // 配色
    static let latestFill = Color(red: 0.24, green: 0.42, blue: 0.85).opacity(0.30)
    static let latestStroke = Color(red: 0.45, green: 0.62, blue: 1.0).opacity(0.65)
    static let olderFill = Color.white.opacity(0.06)
    static let englishBand = Color.black.opacity(0.22)
    static let wordFill = Color(red: 0.95, green: 0.62, blue: 0.20).opacity(0.18)
    static let wordStroke = Color(red: 1.0, green: 0.72, blue: 0.30).opacity(0.55)
    static let savedHighlight = Color(red: 1.0, green: 0.82, blue: 0.25).opacity(0.30)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if model.editing { editor }
            history
            if model.word != nil || model.wordLoading != nil {
                wordCard
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        HStack(spacing: 10) {
            if model.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            }
            if model.auto {
                Text("自動")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.green.opacity(0.35), in: Capsule())
                    .help("自動翻譯開啟中（⌃⌥A 切換）")
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.status)
            Spacer()
            if store.dueCount > 0 {
                Button(action: actions.openReview) {
                    Label("複習 \(store.dueCount)", systemImage: "rectangle.stack")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.35), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("今天有 \(store.dueCount) 張單字卡要複習，點這裡開始")
            }
            iconButton("pencil", help: "修正最後一句的原文後重新翻譯", action: actions.beginEdit)
                .disabled(model.english.isEmpty || model.editing)
            iconButton("arrow.clockwise", help: "重新擷取並翻譯（⌃⌥R）", action: actions.retranslate)
            iconButton("trash", help: "清空清單", action: actions.clear)
                .disabled(model.entries.isEmpty)
            iconButton("gearshape", help: "設定", action: actions.openSettings)
            iconButton("xmark", help: "隱藏（⌃⌥H 再叫出來）", action: actions.hide)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 累積的翻譯清單

    private var history: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.entries.isEmpty {
                        Text("翻譯會一句一句出現在這裡。\n點英文單字可以查字典、收藏到單字本。")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(model.entries) { entry in
                        entryView(entry, isLast: entry.id == model.entries.last?.id)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")  // 捲到這裡＝真正的最底部
                }
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
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

    /// 一句一個色塊：上半是英文（深色帶）、下半是中文；最新一句用藍色強調
    private func entryView(_ entry: OverlayModel.Entry, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.linkedEnglish(entry.english, entryID: entry.id, saved: store.savedForms))
                    .font(.system(size: isLast ? enSize : enSize - 2))
                    .tint(Color.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { actions.speak(entry.english) } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("整句發音")
                Button { actions.explain(entry.id) } label: {
                    Image(systemName: entry.explanation != nil || entry.explaining ? "lightbulb.fill" : "lightbulb")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(entry.explanation != nil || entry.explaining ? Color.yellow : Color.secondary)
                .disabled(entry.explaining || entry.chinese.isEmpty)
                .help("語境解說：請模型解釋這句的方言、文法、用字（約 10～20 秒）")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Self.englishBand)

            Text(entry.chinese.isEmpty ? "…" : entry.chinese)
                .font(.system(size: isLast ? zhSize : zhSize - 4, weight: isLast ? .medium : .regular))
                .foregroundStyle(isLast ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.explaining || entry.explanation != nil {
                explanationView(entry)
            }
        }
        .background(isLast ? Self.latestFill : Self.olderFill)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isLast ? Self.latestStroke : Color.white.opacity(0.08), lineWidth: 1))
    }

    /// 語境解說（黃色區塊）：產生中顯示進度與已產生的部分
    private func explanationView(_ entry: OverlayModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 10)).foregroundStyle(.yellow)
                Text("語境解說").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if entry.explaining {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Text("產生中，約 10～20 秒…").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { actions.closeExplanation(entry.id) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("收起解說")
            }
            if let text = entry.explanation, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10))
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
                        Text(info.word ?? info.query ?? "").font(.system(size: 17, weight: .semibold))
                        if let p = info.phonetic, !p.isEmpty {
                            Text("/\(p)/").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Button { actions.speak(info.word ?? info.query ?? "") } label: {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help("發音")
                        Spacer()
                        Button(action: actions.toggleSave) {
                            Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(saved ? Color.yellow : Color.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.white.opacity(saved ? 0.10 : 0.16), in: Capsule())
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
        .padding(10)
        .background(Self.wordFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Self.wordStroke, lineWidth: 1))
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
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
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
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
