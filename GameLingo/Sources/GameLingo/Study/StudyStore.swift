import Foundation

/// 卡片種類。v3 起每個字只用一張「階梯卡」（ladder），題型依等級變化；
/// meaning／cloze 是 v2 的舊卡，資料保留但不再出題。
enum CardKind: String, CaseIterable {
    case meaning   // v2 意思卡
    case cloze     // v2 克漏字卡
    case ladder    // v3 階梯卡：第 1 層選中文意思、第 2 層選英文字、第 3 層有提示的打字
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
    var level = 1             // 階梯等級 1～3
    var levelStreak = 0       // 這一層連續答對幾次（2 次升級）
    var firstReview: Date?    // 第一次複習的時間（nil＝還沒學過的新字）

    /// 階梯卡的排程
    var ladder: CardScheduler.State? { cards[.ladder] }
    var nextDue: Date { ladder?.due ?? .distantFuture }

    /// 原句裡有這個字（才能做克漏字卡）
    var hasClozeSentence: Bool {
        !sentence.isEmpty && sentence.range(of: form.isEmpty ? word : form, options: .caseInsensitive) != nil
    }

    static func == (a: SavedWord, b: SavedWord) -> Bool {
        a.id == b.id && a.word == b.word && a.morph == b.morph && a.level == b.level && a.levelStreak == b.levelStreak
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
            // v3：階梯卡的等級、連續答對、第一次複習時間；作答紀錄（算答對率與連續天數）
            let cardCols = try db.query("PRAGMA table_info(review_cards)").map { $0.text("name") }
            if !cardCols.contains("level") {
                try db.execute("ALTER TABLE review_cards ADD COLUMN level INTEGER DEFAULT 1")
                try db.execute("ALTER TABLE review_cards ADD COLUMN streak INTEGER DEFAULT 0")
                try db.execute("ALTER TABLE review_cards ADD COLUMN first_review REAL")
            }
            try db.execute("""
                CREATE TABLE IF NOT EXISTS review_log(
                    ts REAL NOT NULL, saved_word_id INTEGER, correct INTEGER NOT NULL, practice INTEGER NOT NULL)
                """)
            self.db = db
        } catch {
            appLog("資料庫開啟失敗：\(error.localizedDescription)")
            self.db = nil
        }
        reload()
        ensureLadderCards()
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
            // 新卡片今天就能複習（受每日新字上限限制）；已有卡片則保留原本的排程
            try addCard(id: id, kind: .ladder, due: now)
        } catch {
            appLog("收藏失敗：\(error.localizedDescription)")
        }
        reload()
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

    /// 每個字補上階梯卡。v2 的舊卡會換算過來：沿用最早到期的排程，複習過的字從第 2 或第 3 層開始。
    private func ensureLadderCards() {
        guard let db else { return }
        var added = false
        for w in words where w.cards[.ladder] == nil {
            let old = w.cards.values
            let reps = old.map(\.reps).max() ?? 0
            let soonest = old.min { $0.due < $1.due }
            let level = reps >= 3 ? 3 : (reps >= 1 ? 2 : 1)
            let reviewed = old.contains { $0.reps > 0 || $0.lapses > 0 }
            try? db.execute("""
                INSERT OR IGNORE INTO review_cards(saved_word_id, kind, due, interval_days, ease, reps, lapses,
                    level, streak, first_review)
                VALUES (?, 'ladder', ?, ?, ?, ?, ?, ?, 0, ?)
                """, [.int(w.id), .double((soonest?.due ?? Date()).timeIntervalSince1970),
                      .int(Int64(soonest?.intervalDays ?? 0)), .double(soonest?.ease ?? 2.5),
                      .int(Int64(reps)), .int(Int64(old.map(\.lapses).reduce(0, +))), .int(Int64(level)),
                      reviewed ? .double(w.createdAt.timeIntervalSince1970) : .null])
            added = true
        }
        if added { reload() }
    }

    // MARK: - 複習

    private func ladderCard(_ w: SavedWord) -> ReviewCard? {
        w.ladder.map { ReviewCard(word: w, kind: .ladder, state: $0) }
    }

    /// 今天要複習的卡：學過且今天到期的（最早到期在前），加上新字（先收藏的先學），新字每天有上限
    func dueCards(now: Date = Date()) -> [ReviewCard] {
        let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86_400)
        let due = words.filter { $0.firstReview != nil && $0.nextDue < end }
            .sorted { $0.nextDue < $1.nextDue }
        let newSlots = max(0, AppSettings.newWordsPerDay - newWordsLearnedToday(now: now))
        let fresh = words.filter { $0.firstReview == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(newSlots)
        return (due + fresh).compactMap(ladderCard)
    }

    /// 今天第一次學的新字數
    func newWordsLearnedToday(now: Date = Date()) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return words.filter { ($0.firstReview ?? .distantPast) >= start }.count
    }

    /// 還沒學過、排隊中的新字
    var waitingNewWords: Int { words.filter { $0.firstReview == nil }.count }

    /// 額外練習用：全部（或只要忘記過的）學過的字，隨機排。不影響排程。
    func practiceCards(onlyLapsed: Bool) -> [ReviewCard] {
        words.filter { $0.firstReview != nil && (!onlyLapsed || ($0.ladder?.lapses ?? 0) > 0) }
            .shuffled()
            .compactMap(ladderCard)
    }

    /// 忘記過的字數（「只練忘記過的」用）
    var lapsedCardCount: Int { words.filter { $0.firstReview != nil && ($0.ladder?.lapses ?? 0) > 0 }.count }
    /// 學過的字數（「全部再練一輪」用）
    var learnedCount: Int { words.filter { $0.firstReview != nil }.count }

    /// 記下一題的結果：更新 SM-2 排程與階梯等級（答對 2 次升一層、答錯降一層），並寫作答紀錄。
    /// 自己指定練習方式時（updateLevel = false）只更新排程，等級不變。
    func answer(_ card: ReviewCard, _ answer: CardScheduler.Answer, correct: Bool, updateLevel: Bool = true) {
        guard let db else { return }
        let w = words.first { $0.id == card.word.id } ?? card.word
        let n = CardScheduler.next(card.state, answer: answer)
        var level = w.level, streak = w.levelStreak
        if !updateLevel {
            // 等級不變
        } else if correct {
            streak += 1
            if streak >= 2, level < 3 { level += 1; streak = 0 }
        } else {
            level = max(1, level - 1)
            streak = 0
        }
        let now = Date().timeIntervalSince1970
        try? db.execute("""
            UPDATE review_cards SET due = ?, interval_days = ?, ease = ?, reps = ?, lapses = ?, last_review = ?,
                level = ?, streak = ?, first_review = COALESCE(first_review, ?)
            WHERE saved_word_id = ? AND kind = 'ladder'
            """, [.double(n.due.timeIntervalSince1970), .int(Int64(n.intervalDays)), .double(n.ease),
                  .int(Int64(n.reps)), .int(Int64(n.lapses)), .double(now), .int(Int64(level)), .int(Int64(streak)),
                  .double(now), .int(card.word.id)])
        log(wordID: card.word.id, correct: correct, practice: false)
        reload()
    }

    /// 練習或再考一次的題目：只記紀錄，不動排程
    func logPractice(wordID: Int64, correct: Bool) {
        log(wordID: wordID, correct: correct, practice: true)
    }

    private func log(wordID: Int64, correct: Bool, practice: Bool) {
        try? db?.execute("INSERT INTO review_log(ts, saved_word_id, correct, practice) VALUES (?,?,?,?)",
                         [.double(Date().timeIntervalSince1970), .int(wordID), .int(correct ? 1 : 0),
                          .int(practice ? 1 : 0)])
    }

    /// 今天作答幾題、答對幾題（含練習）
    func todayStats(now: Date = Date()) -> (answered: Int, correct: Int) {
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        guard let r = try? db?.query("SELECT COUNT(*) AS n, COALESCE(SUM(correct), 0) AS c FROM review_log WHERE ts >= ?",
                                     [.double(start)]).first else { return (0, 0) }
        return (Int(r.int("n")), Int(r.int("c")))
    }

    /// 連續幾天有複習（今天還沒複習就從昨天往回算）
    func streakDays(now: Date = Date()) -> Int {
        guard let rows = try? db?.query("SELECT DISTINCT date(ts, 'unixepoch', 'localtime') AS d FROM review_log") else { return 0 }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let days = Set(rows.map { $0.text("d") })
        let cal = Calendar.current
        var day = now
        if !days.contains(f.string(from: day)) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(f.string(from: day)) {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    // MARK: - 讀取

    func reload() {
        guard let db,
              let rows = try? db.query("SELECT * FROM saved_words ORDER BY created_at DESC"),
              let cardRows = try? db.query("SELECT * FROM review_cards") else { return }
        var cardsByWord: [Int64: [CardKind: CardScheduler.State]] = [:]
        var ladderInfo: [Int64: (level: Int, streak: Int, first: Date?)] = [:]
        for r in cardRows {
            guard let kind = CardKind(rawValue: r.text("kind")) else { continue }
            if kind == .ladder {
                let first = r.double("first_review")
                ladderInfo[r.int("saved_word_id")] = (max(1, min(3, Int(r.int("level")))), Int(r.int("streak")),
                                                      first > 0 ? Date(timeIntervalSince1970: first) : nil)
            }
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
                      cards: cardsByWord[r.int("id")] ?? [:],
                      level: ladderInfo[r.int("id")]?.level ?? 1,
                      levelStreak: ladderInfo[r.int("id")]?.streak ?? 0,
                      firstReview: ladderInfo[r.int("id")]?.first)
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
