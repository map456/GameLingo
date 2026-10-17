import Foundation

/// 卡片種類：同一個收藏的字有兩張卡，各自排程
enum CardKind: String, CaseIterable {
    case meaning   // 意思卡：看英文 → 想中文
    case cloze     // 克漏字卡：看挖空的遊戲原句 → 想出英文字
}

/// 一個收藏的單字（含遊戲原句、字根拆解與複習排程）
struct SavedWord: Identifiable, Equatable {
    let id: Int64
    var word: String          // 原形（例如 disappear）
    var form: String          // 遊戲裡出現的樣子（例如 disappearin'）
    var phonetic: String
    var definition: [String]  // 中文釋義（每行一個詞性）
    var sentence: String      // 遊戲原句
    var sentenceZh: String    // 原句翻譯
    var createdAt: Date
    var morph: MorphInfo?
    var cards: [CardKind: CardScheduler.State]

    /// 最早到期的那張卡
    var nextDue: Date { cards.values.map(\.due).min() ?? .distantFuture }

    /// 原句裡有這個字（才能做克漏字卡）
    var hasClozeSentence: Bool {
        !sentence.isEmpty && sentence.range(of: form.isEmpty ? word : form, options: .caseInsensitive) != nil
    }

    static func == (a: SavedWord, b: SavedWord) -> Bool {
        a.id == b.id && a.word == b.word && a.morph == b.morph
            && a.cards.mapValues { "\($0.due.timeIntervalSince1970)-\($0.reps)" }
            == b.cards.mapValues { "\($0.due.timeIntervalSince1970)-\($0.reps)" }
    }
}

/// 一張要複習的卡（哪個字＋哪一種）
struct ReviewCard: Identifiable, Equatable {
    var word: SavedWord
    var kind: CardKind
    var state: CardScheduler.State
    var id: String { "\(word.id)-\(kind.rawValue)" }
}

/// 學習資料：翻譯歷史、收藏單字、單字卡排程。
/// 存在 ~/Library/Application Support/GameLingo/study.sqlite（與唯讀的 ECDICT 分開）。
@MainActor
final class StudyStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []
    @Published private(set) var dueCount = 0
    /// 已收藏的字（原形＋出現時的樣子，小寫），用來在句子裡標出來、切換星號
    @Published private(set) var savedForms: Set<String> = []

    private let db: SQLiteDB?

    init() {
        let path = AppPaths.support.appendingPathComponent("study.sqlite").path
        do {
            let db = try SQLiteDB(path: path)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS lines(
                    id INTEGER PRIMARY KEY, english TEXT NOT NULL, chinese TEXT NOT NULL,
                    model TEXT, created_at REAL)
                """)
            try db.execute("""
                CREATE TABLE IF NOT EXISTS saved_words(
                    id INTEGER PRIMARY KEY, word TEXT NOT NULL UNIQUE COLLATE NOCASE, form TEXT,
                    phonetic TEXT, definition TEXT, sentence TEXT, sentence_zh TEXT,
                    line_id INTEGER REFERENCES lines(id), note TEXT DEFAULT '', created_at REAL)
                """)
            // v2：字根拆解（JSON）
            let cols = try db.query("PRAGMA table_info(saved_words)").map { $0.text("name") }
            if !cols.contains("morph") {
                try db.execute("ALTER TABLE saved_words ADD COLUMN morph TEXT")
            }
            // v2：每個字有「意思卡」與「克漏字卡」兩張，各自排程
            try db.execute("""
                CREATE TABLE IF NOT EXISTS review_cards(
                    saved_word_id INTEGER NOT NULL REFERENCES saved_words(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, due REAL, interval_days INTEGER, ease REAL, reps INTEGER,
                    lapses INTEGER, last_review REAL, PRIMARY KEY(saved_word_id, kind))
                """)
            // 從 v1 的 cards 表搬過來（只做一次）
            let hasV1 = try !db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='cards'").isEmpty
            if hasV1 {
                try db.execute("""
                    INSERT OR IGNORE INTO review_cards
                    SELECT saved_word_id, 'meaning', due, interval_days, ease, reps, lapses, last_review FROM cards
                    """)
                try db.execute("DROP TABLE cards")
            }
            self.db = db
        } catch {
            appLog("資料庫開啟失敗：\(error.localizedDescription)")
            self.db = nil
        }
        reload()
        ensureClozeCards()
    }

    // MARK: - 翻譯歷史

    private var lastLine: (english: String, id: Int64)?

    /// 記一句翻譯，回傳 line id（同一句連續記錄只記一次）
    @discardableResult
    func recordLine(english: String, chinese: String, model: String) -> Int64? {
        guard let db else { return nil }
        if let lastLine, lastLine.english == english {
            try? db.execute("UPDATE lines SET chinese = ? WHERE id = ?", [.text(chinese), .int(lastLine.id)])
            return lastLine.id
        }
        try? db.execute("INSERT INTO lines(english, chinese, model, created_at) VALUES (?,?,?,?)",
                        [.text(english), .text(chinese), .text(model), .double(Date().timeIntervalSince1970)])
        lastLine = (english, db.lastInsertID)
        return db.lastInsertID
    }

    /// 最近 n 句翻譯（舊的在前），App 啟動時放回翻譯視窗
    func recentLines(_ n: Int) -> [(english: String, chinese: String)] {
        guard let db, let rows = try? db.query(
            "SELECT english, chinese FROM lines WHERE chinese <> '' ORDER BY id DESC LIMIT ?", [.int(Int64(n))])
        else { return [] }
        return rows.reversed().map { ($0.text("english"), $0.text("chinese")) }
    }

    /// 第一次使用資料庫時，把之前存在 history.jsonl 的翻譯匯入（只做一次）
    func importHistoryIfEmpty() {
        guard let db, (try? db.query("SELECT COUNT(*) AS n FROM lines"))?.first?.int("n") == 0,
              let text = try? String(contentsOf: AppPaths.history, encoding: .utf8) else { return }
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let en = obj["english"] as? String, let zh = obj["chinese"] as? String,
                  !zh.isEmpty, !seen.contains(en) else { continue }
            seen.insert(en)
            let t = (obj["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            try? db.execute("INSERT INTO lines(english, chinese, model, created_at) VALUES (?,?,?,?)",
                            [.text(en), .text(zh), .text(obj["model"] as? String ?? ""), .double(t.timeIntervalSince1970)])
        }
    }

    // MARK: - 收藏

    func isSaved(_ word: String) -> Bool { savedForms.contains(word.lowercased()) }

    func save(word: String, form: String, phonetic: String, definition: [String], sentence: String,
              sentenceZh: String, morph: MorphInfo?) {
        guard let db else { return }
        let now = Date().timeIntervalSince1970
        let lineID = (try? db.query("SELECT id FROM lines WHERE english = ? ORDER BY id DESC LIMIT 1",
                                    [.text(sentence)]))?.first?.int("id")
        do {
            try db.execute("""
                INSERT INTO saved_words(word, form, phonetic, definition, sentence, sentence_zh, line_id, created_at, morph)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(word) DO UPDATE SET form = excluded.form, sentence = excluded.sentence,
                    sentence_zh = excluded.sentence_zh, line_id = excluded.line_id,
                    morph = COALESCE(excluded.morph, saved_words.morph)
                """, [.text(word), .text(form), .text(phonetic), .text(definition.joined(separator: "\n")),
                      .text(sentence), .text(sentenceZh), lineID.map { .int($0) } ?? .null, .double(now),
                      Self.encode(morph)])
            let id = try db.query("SELECT id FROM saved_words WHERE word = ?", [.text(word)]).first?.int("id") ?? 0
            // 新卡片今天就能複習；已有卡片則保留原本的排程
            try addCard(id: id, kind: .meaning, due: now)
        } catch {
            appLog("收藏失敗：\(error.localizedDescription)")
        }
        reload()
        ensureClozeCards()
    }

    /// 用原形或出現時的樣子取消收藏
    func unsave(_ wordOrForm: String) {
        guard let db else { return }
        try? db.execute("DELETE FROM saved_words WHERE word = ? COLLATE NOCASE OR form = ? COLLATE NOCASE",
                        [.text(wordOrForm), .text(wordOrForm)])
        reload()
    }

    func delete(id: Int64) {
        try? db?.execute("DELETE FROM saved_words WHERE id = ?", [.int(id)])
        reload()
    }

    func setMorph(id: Int64, _ morph: MorphInfo) {
        try? db?.execute("UPDATE saved_words SET morph = ? WHERE id = ?", [Self.encode(morph), .int(id)])
        reload()
    }

    /// 還沒有字根拆解的字（舊版收藏的），App 啟動後補查
    var wordsMissingMorph: [SavedWord] { words.filter { $0.morph == nil } }

    /// 同字根家族：單字本裡和這個字有共同字根的其他字
    func family(of w: SavedWord) -> [SavedWord] {
        let roots = Set(w.morph?.roots ?? [w.word.lowercased()])
        return words.filter { $0.id != w.id && !roots.isDisjoint(with: $0.morph?.roots ?? [$0.word.lowercased()]) }
    }

    private func addCard(id: Int64, kind: CardKind, due: Double) throws {
        try db?.execute("""
            INSERT OR IGNORE INTO review_cards(saved_word_id, kind, due, interval_days, ease, reps, lapses)
            VALUES (?, ?, ?, 0, 2.5, 0, 0)
            """, [.int(id), .text(kind.rawValue), .double(due)])
    }

    /// 原句裡找得到這個字的收藏，補上克漏字卡（今天就能複習）
    private func ensureClozeCards() {
        let now = Date().timeIntervalSince1970
        var added = false
        for w in words where w.cards[.cloze] == nil && w.hasClozeSentence {
            try? addCard(id: w.id, kind: .cloze, due: now)
            added = true
        }
        if added { reload() }
    }

    // MARK: - 複習

    /// 今天結束前到期的卡片，最早到期的在前；同一個字的兩張卡盡量不要連著出
    func dueCards(now: Date = Date()) -> [ReviewCard] {
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        var cards = words.flatMap { w in
            w.cards.compactMap { kind, state in state.due < end ? ReviewCard(word: w, kind: kind, state: state) : nil }
        }.sorted { ($0.state.due, $0.kind.rawValue) < ($1.state.due, $1.kind.rawValue) }
        var i = 1
        while i < cards.count {
            if cards[i].word.id == cards[i - 1].word.id,
               let j = cards[(i + 1)...].firstIndex(where: { $0.word.id != cards[i].word.id }) {
                cards.swapAt(i, j)
            }
            i += 1
        }
        return cards
    }

    /// 額外練習用：全部卡片（或只要忘記過的）隨機排，同一字的兩張卡不連續。不影響排程。
    func practiceCards(onlyLapsed: Bool) -> [ReviewCard] {
        var cards = words.flatMap { w in
            w.cards.compactMap { kind, state in
                !onlyLapsed || state.lapses > 0 ? ReviewCard(word: w, kind: kind, state: state) : nil
            }
        }.shuffled()
        var i = 1
        while i < cards.count {
            if cards[i].word.id == cards[i - 1].word.id,
               let j = cards[(i + 1)...].firstIndex(where: { $0.word.id != cards[i].word.id }) {
                cards.swapAt(i, j)
            }
            i += 1
        }
        return cards
    }

    /// 忘記過的卡片張數（「只練常忘記的」用）
    var lapsedCardCount: Int { words.reduce(0) { $0 + $1.cards.values.filter { $0.lapses > 0 }.count } }

    func answer(_ card: ReviewCard, _ answer: CardScheduler.Answer) {
        guard let db else { return }
        let n = CardScheduler.next(card.state, answer: answer)
        try? db.execute("""
            UPDATE review_cards SET due = ?, interval_days = ?, ease = ?, reps = ?, lapses = ?, last_review = ?
            WHERE saved_word_id = ? AND kind = ?
            """, [.double(n.due.timeIntervalSince1970), .int(Int64(n.intervalDays)), .double(n.ease),
                  .int(Int64(n.reps)), .int(Int64(n.lapses)), .double(Date().timeIntervalSince1970),
                  .int(card.word.id), .text(card.kind.rawValue)])
        reload()
    }

    // MARK: - 讀取

    func reload() {
        guard let db,
              let rows = try? db.query("SELECT * FROM saved_words ORDER BY created_at DESC"),
              let cardRows = try? db.query("SELECT * FROM review_cards") else { return }
        var cardsByWord: [Int64: [CardKind: CardScheduler.State]] = [:]
        for r in cardRows {
            guard let kind = CardKind(rawValue: r.text("kind")) else { continue }
            cardsByWord[r.int("saved_word_id"), default: [:]][kind] = .init(
                intervalDays: Int(r.int("interval_days")), ease: r.double("ease"),
                reps: Int(r.int("reps")), lapses: Int(r.int("lapses")),
                due: Date(timeIntervalSince1970: r.double("due")))
        }
        words = rows.map { r in
            SavedWord(id: r.int("id"), word: r.text("word"), form: r.text("form"), phonetic: r.text("phonetic"),
                      definition: r.text("definition").split(separator: "\n").map(String.init),
                      sentence: r.text("sentence"), sentenceZh: r.text("sentence_zh"),
                      createdAt: Date(timeIntervalSince1970: r.double("created_at")),
                      morph: r.text("morph").isEmpty ? nil
                          : try? JSONDecoder().decode(MorphInfo.self, from: Data(r.text("morph").utf8)),
                      cards: cardsByWord[r.int("id")] ?? [:])
        }
        savedForms = Set(words.flatMap { [$0.word.lowercased(), $0.form.lowercased()] })
        dueCount = dueCards().count
    }

    private static func encode(_ morph: MorphInfo?) -> SQLiteDB.Value {
        guard let morph, let data = try? JSONEncoder().encode(morph),
              let s = String(data: data, encoding: .utf8) else { return .null }
        return .text(s)
    }
}
