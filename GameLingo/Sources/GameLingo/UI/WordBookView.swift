import SwiftUI

/// 我的單字本：所有收藏的單字，可搜尋、發音、刪除。
struct WordBookView: View {
    @ObservedObject var store: StudyStore
    var startReview: () -> Void
    @State private var search = ""

    private var filtered: [SavedWord] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.words }
        return store.words.filter {
            $0.word.lowercased().contains(q) || $0.form.lowercased().contains(q)
                || $0.definition.joined().contains(q) || $0.sentence.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("我的單字本").font(.headline)
                Text("\(store.words.count) 個單字").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                TextField("搜尋", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button(action: startReview) {
                    Label(store.dueCount > 0 ? "複習（\(store.dueCount)）" : "複習", systemImage: "rectangle.stack")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.dueCount == 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.04))

            if store.words.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "star").font(.system(size: 36)).foregroundStyle(.yellow)
                    Text("還沒有收藏的單字").font(.title3.bold())
                    Text("玩遊戲時點翻譯視窗裡的英文單字，在字卡上按「☆ 收藏」。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(filtered) { w in
                        row(w)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func row(_ w: SavedWord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(w.word).font(.system(size: 16, weight: .semibold))
                    if !w.phonetic.isEmpty {
                        Text("/\(w.phonetic)/").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !w.form.isEmpty, w.form.lowercased() != w.word.lowercased() {
                        Text("遊戲裡：\(w.form)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(w.definition.prefix(2).joined(separator: "　"))
                    .font(.system(size: 13))
                    .lineLimit(2)
                if let m = w.morph, m.isUseful {
                    MorphChips(morph: m, compact: true)
                }
                if !w.sentence.isEmpty {
                    Text(FlashcardView.highlighted(w.sentence, word: w.form.isEmpty ? w.word : w.form))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(dueText(w)).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { SpeechService.shared.speak(w.word) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.borderless)
                        .help("發音")
                    Button { store.delete(id: w.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("從單字本刪除")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func dueText(_ w: SavedWord) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: w.nextDue)).day ?? 0
        if w.firstReview == nil { return "新字・排隊中" }
        let level = "第 \(w.level) 層・"
        if days <= 0 { return level + "今天複習" }
        return level + (days == 1 ? "明天複習" : "\(days) 天後複習")
    }
}

/// 管理「單字卡複習」與「我的單字本」兩個一般視窗（會拿到鍵盤焦點，在不玩遊戲時用）
@MainActor
final class StudyWindows {
    private let store: StudyStore
    private let lookup: WordLookup
    private let dictionary: DictionaryClient
    private var reviewWindow: NSWindow?
    private var bookWindow: NSWindow?
    private var sizeObservation: NSKeyValueObservation?

    init(store: StudyStore, dictionary: DictionaryClient) {
        self.store = store
        self.lookup = WordLookup(client: dictionary)
        self.dictionary = dictionary
    }

    /// 單字卡或單字本開著時，不要把焦點還給遊戲
    var isStudying: Bool {
        (reviewWindow?.isVisible ?? false) || (bookWindow?.isVisible ?? false)
    }

    func showReview() {
        store.reload()
        // 每次開都重建內容，重新抓今天到期的卡片
        let w = reviewWindow ?? makeWindow(title: "單字卡複習", size: NSSize(width: 560, height: 500), autosave: "GameLingoReview")
        let host = NSHostingController(rootView: FlashcardView(store: store, lookup: lookup, dictionary: dictionary))
        // SwiftUI 算出內容需要多高（翻面、查字時會變），視窗就跟著改高度，不用自己捲動
        host.sizingOptions = [.preferredContentSize]
        w.contentViewController = host
        // 深色漸層外觀：標題列透明、底色和漸層頂端同色，看起來連成一片。
        // 不能用 .fullSizeContentView：視窗跟著內容改高度時，安全區域會一直變動，AppKit 無限重排而當掉。
        w.titlebarAppearsTransparent = true
        w.backgroundColor = NSColor(Theme.bgTop)
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        sizeObservation = host.observe(\.preferredContentSize, options: [.initial, .new]) { [weak w] host, _ in
            let size = host.preferredContentSize
            DispatchQueue.main.async {
                guard let w, size.width > 100, size.height > 100 else { return }
                StudyWindows.fit(w, contentSize: size)
            }
        }
        reviewWindow = w
        present(w)
    }

    func showWordBook() {
        store.reload()
        let w = bookWindow ?? makeWindow(title: "我的單字本", size: NSSize(width: 640, height: 520), autosave: "GameLingoWordBook")
        if bookWindow == nil {
            w.contentViewController = NSHostingController(rootView: WordBookView(store: store) { [weak self] in
                self?.showReview()
            })
        }
        bookWindow = w
        present(w)
    }

    /// 把視窗內容區設成指定大小（保持上緣不動、不超出螢幕）
    static func fit(_ w: NSWindow, contentSize: NSSize) {
        guard let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var target = w.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        target.size.height = min(target.height, vf.height)
        var f = w.frame
        if abs(target.height - f.height) < 1, abs(target.width - f.width) < 1 { return }
        let top = f.maxY
        f.size = target.size
        f.origin.y = top - f.height
        if f.minY < vf.minY { f.origin.y = vf.minY }            // 往下長到底了，改成往上長
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        w.setFrame(f, display: true, animate: false)
    }

    private func makeWindow(title: String, size: NSSize, autosave: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName(autosave)
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
