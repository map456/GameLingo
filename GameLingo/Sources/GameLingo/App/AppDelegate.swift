import AppKit
import Carbon
import Combine
import ImageIO
import UniformTypeIdentifiers

/// 殼層：選單列圖示、快捷鍵、權限、翻譯伺服器，串起「擷取 → OCR → 翻譯 → 顯示」。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = ModelServer()
    private let capture = CaptureService()
    private lazy var translator = TranslationCoordinator(client: SeedXClient(baseURL: server.baseURL))
    private lazy var dictionary = DictionaryClient(baseURL: server.baseURL)
    private var lookupTask: Task<Void, Never>?
    private let model = OverlayModel()
    private let store = StudyStore()
    private lazy var studyWindows = StudyWindows(store: store, dictionary: dictionary)
    private var reviewMenuItem: NSMenuItem!
    private var bookMenuItem: NSMenuItem!
    private var cancellables: Set<AnyCancellable> = []
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var serverMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var openEmuMenuItem: NSMenuItem!
    private var autoMenuItem: NSMenuItem!

    private var captureTask: Task<Void, Never>?
    private var lastText = ""
    private var lastCropFile: String?
    private var recentTexts: [String] = []  // 最近翻過的 5 句，擋掉 OCR 小差異造成的重複翻譯
    private var autoTask: Task<Void, Never>?

    /// 自動翻譯開關（記在 UserDefaults，預設開啟）
    private var autoEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.Key.autoTranslate) }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.Key.autoTranslate) }
    }
    private var unloadTask: Task<Void, Never>?
    private var explanationCache: [String: String] = [:]
    private var explainTasks: [UUID: Task<Void, Never>] = [:]
    private lazy var settingsWindow = SettingsWindow()

    // MARK: - 啟動

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.register()
        panel = OverlayPanel(model: model, store: store, actions: .init(
            retranslate: { [weak self] in self?.translateCurrent(force: true) },
            beginEdit: { [weak self] in self?.beginEdit() },
            submitEdit: { [weak self] in self?.submitEdit() },
            cancelEdit: { [weak self] in self?.endEdit() },
            hide: { [weak self] in self?.panel.orderOut(nil) },
            lookup: { [weak self] word, entry in
                self?.model.wordEntry = entry ?? self?.model.entries.last
                self?.lookupWord(word)
            },
            closeWord: { [weak self] in
                self?.model.word = nil
                self?.model.wordLoading = nil
            },
            speak: { text in SpeechService.shared.speak(text) },
            clear: { [weak self] in
                self?.model.entries.removeAll()
                self?.model.word = nil
            },
            toggleSave: { [weak self] in self?.toggleSave() },
            openReview: { [weak self] in self?.studyWindows.showReview() },
            explain: { [weak self] id in self?.explain(entryID: id) },
            openSettings: { [weak self] in self?.settingsWindow.show() },
            closeExplanation: { [weak self] id in
                guard let self, let i = self.model.entries.firstIndex(where: { $0.id == id }) else { return }
                self.model.entries[i].explanation = nil
            }
        ))

        // 把上次的翻譯放回清單（重開 App 不會清空）
        store.importHistoryIfEmpty()
        for line in store.recentLines(30) {
            model.begin(line.english)
            model.setChinese(line.chinese)
        }
        // 重開 App 後也記得最近翻過的句子，避免畫面上同一句又被翻一次
        recentTexts = Array(model.entries.suffix(5).map(\.english))
        lastText = model.entries.last?.english ?? ""

        setUpMenu()
        registerHotkeys()
        observeOpenEmu()

        server.onChange = { [weak self] in
            self?.refreshMenu()
            if self?.server.canLookup == true { self?.backfillMorph() }
        }
        // 不玩的時候不載入模型（省約 8 GB 記憶體）；OpenEmu 一開就載入
        server.start(loadModel: !AppSettings.releaseMemory || isOpenEmuRunning)
        _ = KnownNames.load()  // 第一次執行時建立名字清單檔

        if !Permissions.hasScreenCapture {
            Permissions.requestScreenCapture()
        }
        refreshMenu()
        panel.orderFrontRegardless()
        model.status = "模型載入中…"
        setAuto(autoEnabled, announce: false)
        returnFocusToGame()
        if ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_REVIEW"] == "1" {
            studyWindows.showReview()  // 測試用：啟動就開複習視窗
        }
        // 測試用：GAMELINGO_DEBUG_OVERLAY_LOOKUP=字 時 4 秒後在翻譯視窗查這個字（檢查視窗會不會被撐高）
        if let w = ProcessInfo.processInfo.environment["GAMELINGO_DEBUG_OVERLAY_LOOKUP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.lookupWord(w) }
        }

        // 設定改了就套用（透明度；自動翻譯間隔與字級由各自的地方即時讀取）
        panel.alphaValue = AppSettings.panelOpacity
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.panel.alphaValue = AppSettings.panelOpacity
                if self.model.auto != self.autoEnabled { self.setAuto(self.autoEnabled, announce: false) }
                // 換了翻譯模型 → 重新啟動伺服器（OpenEmu 開著才馬上載入）
                if let launched = self.server.launchedModel, launched != AppSettings.translationModel {
                    appLog("切換翻譯模型：\(AppSettings.translationModel.rawValue)")
                    self.explanationCache.removeAll()
                    self.server.restart(loadModel: !AppSettings.releaseMemory || self.isOpenEmuRunning)
                }
            }
            .store(in: &cancellables)

        // 選單列顯示今天待複習的張數；每 10 分鐘重算一次（跨日時會更新）
        store.$dueCount.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshStudyMenu() }.store(in: &cancellables)
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.reload() }
        }
    }

    /// 把鍵盤焦點還給遊戲（GameLingo 被開啟或編輯完原文時，系統可能把焦點交給我們）
    private func returnFocusToGame() {
        if panel.isKeyWindow { panel.resignKey() }
        if let openEmu = NSRunningApplication.runningApplications(withBundleIdentifier: CaptureService.openEmuBundleID).first {
            openEmu.activate()
        } else {
            NSApp.deactivate()
        }
    }

    /// 我們的 App 不應該停在前景：一被切到前景（例如用 open 指令開啟）就把焦點還回去
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !model.editing, !studyWindows.isStudying, !settingsWindow.isVisible else { return }
        DispatchQueue.main.async { [weak self] in self?.returnFocusToGame() }
    }

    /// App 已經在執行時又被打開（open 指令、雙擊 App）→ 把翻譯視窗叫出來
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: - 快捷鍵

    private func registerHotkeys() {
        let mods = controlKey | optionKey
        let hk = HotkeyService.shared
        let ok1 = hk.register(id: 1, keyCode: kVK_ANSI_T, modifiers: mods) { [weak self] in
            self?.translateCurrent(force: false)
        }
        let ok2 = hk.register(id: 2, keyCode: kVK_ANSI_R, modifiers: mods) { [weak self] in
            self?.translateCurrent(force: true)
        }
        let ok3 = hk.register(id: 3, keyCode: kVK_ANSI_H, modifiers: mods) { [weak self] in
            self?.togglePanel()
        }
        let ok4 = hk.register(id: 4, keyCode: kVK_ANSI_A, modifiers: mods) { [weak self] in
            guard let self else { return }
            self.setAuto(!self.autoEnabled, announce: true)
        }
        if !(ok1 && ok2 && ok3 && ok4) {
            model.status = "有快捷鍵註冊失敗（可能被其他 App 佔用），可改用選單列操作"
        }
    }

    // MARK: - 主流程

    /// force＝重新翻譯：不管是不是同一句、不查快取
    private func translateCurrent(force: Bool) {
        guard !model.editing else { return }
        panel.orderFrontRegardless()

        if case .failed(let msg) = server.state {
            model.status = msg
            return
        }

        captureTask?.cancel()
        model.busy = true
        model.status = "擷取中…"
        captureTask = Task {
            // 模型被卸載了（不玩一陣子）就先載回來，約 1～5 秒
            guard await ensureModel() else { return }
            let t0 = Date()
            do {
                let shot = try await capture.captureOpenEmu()
                if Task.isCancelled { return }
                model.status = "辨識文字中…"
                let reading = await Task.detached(priority: .userInitiated) { DialogueReader.read(shot) }.value
                if Task.isCancelled { return }
                let ocrSeconds = Date().timeIntervalSince(t0)

                guard let reading else {
                    model.busy = false
                    model.status = "畫面上沒有對話框"
                    return
                }
                guard !reading.text.isEmpty else {
                    model.busy = false
                    model.status = "對話框裡沒有讀到文字"
                    return
                }
                if !force && reading.text == lastText {
                    model.busy = false
                    model.status = "跟上一句相同"
                    return
                }
                lastText = reading.text
                remember(reading.text)
                lastCropFile = saveCrop(reading.crop)
                startTranslation(reading.text, force: force, ocrSeconds: ocrSeconds)
            } catch CaptureError.noPermission {
                model.busy = false
                model.status = "需要螢幕錄製權限：點選單列圖示 →「開啟螢幕錄製權限設定」"
                Permissions.requestScreenCapture()
                refreshMenu()
            } catch {
                appLog("手動翻譯擷取失敗：\(error.localizedDescription)")
                model.busy = false
                model.status = error.localizedDescription
            }
        }
    }

    private func startTranslation(_ text: String, force: Bool, ocrSeconds: Double?) {
        model.begin(text)
        let ocrPart = ocrSeconds.map { String(format: "OCR %.1fs", $0) }

        if !force, let hit = translator.cached(text) {
            model.setChinese(hit)
            model.busy = false
            model.status = [ocrPart, "快取"].compactMap { $0 }.joined(separator: "・")
            appendHistory(english: text, chinese: hit, seconds: 0, cached: true)
            return
        }

        model.busy = true
        model.status = "翻譯中…"
        translator.translate(text, names: KnownNames.load(), onUpdate: { [weak self] zh in
            self?.model.setChinese(zh)
        }, onDone: { [weak self] zh, seconds, error in
            guard let self else { return }
            self.model.busy = false
            if let error {
                self.model.status = "翻譯失敗：\(error)"
                return
            }
            let zh = zh ?? ""
            self.model.setChinese(zh)
            let tr = seconds.map { String(format: "翻譯 %.1fs", $0) }
            self.model.status = [ocrPart, tr].compactMap { $0 }.joined(separator: "・")
            self.appendHistory(english: text, chinese: zh, seconds: seconds ?? 0, cached: false)
        })
    }

    /// 確保模型已載入；卸載中就載入並等待（最多 60 秒）
    private func ensureModel() async -> Bool {
        if server.state == .ready { return true }
        if case .failed(let msg) = server.state {
            model.busy = false
            model.status = msg
            return false
        }
        model.busy = true
        model.status = "載入翻譯模型中（約幾秒）…"
        server.load()
        for _ in 0..<120 {
            if server.state == .ready { return true }
            if case .failed = server.state { break }
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return false }
        }
        model.busy = false
        if case .failed(let msg) = server.state { model.status = msg } else { model.status = "模型載入逾時" }
        return false
    }

    // MARK: - 自動翻譯

    private func setAuto(_ on: Bool, announce: Bool) {
        autoEnabled = on
        model.auto = on
        autoTask?.cancel()
        autoTask = nil
        if on {
            autoTask = Task { [weak self] in await self?.autoLoop() }
        }
        if announce {
            panel.orderFrontRegardless()
            model.status = on ? "自動翻譯：開啟（對話停住約 1 秒就會翻譯）" : "自動翻譯：關閉（按 ⌃⌥T 手動翻譯）"
        }
        refreshMenu()
    }

    /// 每 1 秒看一次 OpenEmu：對話框文字連續兩次相同（字已經打完）、而且不是剛翻過的句子，就自動翻譯。
    private func autoLoop() async {
        var lastSignature: [UInt8]?
        var lastOCR = ""
        var lastSeen = ""
        var lastError = ""
        appLog("自動翻譯開始")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(AppSettings.autoInterval))
            if Task.isCancelled { return }
            guard server.state == .ready, !model.editing, isOpenEmuRunning else { continue }

            let shot: CGImage
            do {
                shot = try await capture.captureOpenEmu()
            } catch CaptureError.noPermission {
                appLog("自動翻譯：沒有螢幕錄製權限，停止")
                model.status = "自動翻譯需要螢幕錄製權限：點選單列圖示 →「開啟螢幕錄製權限設定」"
                setAuto(false, announce: false)
                return
            } catch {
                // 視窗暫時找不到（切換中、縮到 Dock）就等下一輪；同樣的錯誤只記一次
                let msg = error.localizedDescription
                if msg != lastError { appLog("自動翻譯擷取失敗：\(msg)"); lastError = msg }
                continue
            }
            lastError = ""

            let previous = lastSignature
            let frame = await Task.detached(priority: .utility) {
                DialogueReader.readIfChanged(shot, previous: previous)
            }.value
            if Task.isCancelled { return }
            guard let frame else {
                lastSignature = nil
                lastSeen = ""
                continue
            }
            lastSignature = frame.signature
            if let t = frame.text { lastOCR = t }
            let text = lastOCR

            if let t = frame.text { appLog("自動翻譯 OCR：\(t)") }
            if text == lastSeen, text != lastText, Self.looksLikeSentence(text), !isRepeat(text), !Self.looksLikeMenu(text) {
                appLog("自動翻譯：送出翻譯")
                lastText = text
                remember(text)
                lastCropFile = saveCrop(frame.crop)
                panel.orderFrontRegardless()
                startTranslation(text, force: false, ocrSeconds: nil)
            }
            lastSeen = text
        }
    }

    /// 跟最近 5 句幾乎一樣（相似度 ≥ 0.9）就當成同一句；
    /// 例外：新的字明顯比較長（逐字顯示打完了），要重翻。
    private func isRepeat(_ text: String) -> Bool {
        recentTexts.contains { DialogueReader.similarity(text, $0) >= 0.9 && text.count <= $0.count + 3 }
    }

    /// 商店清單、物品欄也有白色外框；出現 2 個以上「100G」「x 1」這種價格／數量就當成選單，自動模式不翻
    /// （需要的話仍可按 ⌃⌥T 手動翻）
    static func looksLikeMenu(_ text: String) -> Bool {
        let pattern = #"\b\d+\s*[G@฿](?![A-Za-z])|[x×]\s?\d+\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= 2
    }

    /// 至少要有 2 個英文單字才算一句話（擋掉「". Items」這種選單碎片）
    static func looksLikeSentence(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z]{2,}") else { return true }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) >= 2
    }

    private func remember(_ text: String) {
        recentTexts = Array((recentTexts + [text]).suffix(5))
    }

    private var isOpenEmuRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: CaptureService.openEmuBundleID).isEmpty
    }

    // MARK: - 點字查詢

    private func lookupWord(_ word: String) {
        lookupTask?.cancel()
        model.word = nil
        model.wordMorph = nil
        model.wordLoading = word
        lookupTask = Task {
            async let infoReq = dictionary.lookup(word)
            async let morphReq = dictionary.morph(word)
            let (info, morph) = await (infoReq, morphReq)
            if Task.isCancelled { return }
            model.wordMorph = morph
            model.wordLoading = nil
            model.word = info ?? WordInfo(found: false, query: word, word: nil, phonetic: nil,
                                          translation: nil, lemma: nil, error: "查詢失敗：翻譯伺服器沒有回應")
        }
    }

    // MARK: - 語境解說

    /// 請 Seed-X「翻譯並詳細解說」這一句（方言、文法、用字），結果顯示在該句下方
    private func explain(entryID: UUID) {
        guard let i = model.entries.firstIndex(where: { $0.id == entryID }) else { return }
        let english = model.entries[i].english
        // 語境：目前的譯文和前一句（Qwen3 解說會參考，也會指正不自然的翻譯）
        let context = ["zh": model.entries[i].chinese, "prev": i > 0 ? model.entries[i - 1].english : ""]
        if let cached = explanationCache[english] {
            model.entries[i].explanation = cached
            return
        }
        model.entries[i].explaining = true
        model.entries[i].explanation = ""
        let client = SeedXClient(baseURL: server.baseURL)
        explainTasks[entryID] = Task { [weak self] in
            guard let self else { return }
            @MainActor func update(_ body: (inout OverlayModel.Entry) -> Void) {
                if let j = self.model.entries.firstIndex(where: { $0.id == entryID }) { body(&self.model.entries[j]) }
            }
            guard await self.ensureModel() else {
                update { $0.explaining = false; $0.explanation = "模型沒有載入，無法解說" }
                return
            }
            self.refreshMenu()
            do {
                for try await u in client.translate(english, names: KnownNames.load(), mode: "explain", context: context) {
                    if let e = u.error {
                        update { $0.explaining = false; $0.explanation = "解說失敗：\(e)" }
                        return
                    }
                    if u.cancelled { update { $0.explaining = false }; return }
                    if let exp = u.explanation { update { $0.explanation = exp } }
                    if u.done {
                        let text = (u.explanation ?? "").isEmpty ? "模型這次沒有產生解說，可以再按一次 💡 試試。" : u.explanation!
                        if !(u.explanation ?? "").isEmpty { self.explanationCache[english] = text }
                        update { $0.explaining = false; $0.explanation = text }
                        appLog("語境解說完成（\(u.seconds ?? 0) 秒）：\(english.prefix(40))")
                    }
                }
            } catch {
                update { $0.explaining = false; $0.explanation = "解說失敗：\(error.localizedDescription)" }
            }
            update { $0.explaining = false }
            self.explainTasks[entryID] = nil
        }
    }

    // MARK: - 收藏

    private func toggleSave() {
        guard let info = model.word, info.found else { return }
        let head = info.lemma?.word ?? info.word ?? info.query ?? ""
        guard !head.isEmpty else { return }
        if store.isSaved(head) {
            store.unsave(head)
            model.status = "已從單字本移除「\(head)」"
            return
        }
        let entry = model.wordEntry
        store.save(word: head,
                   form: info.query ?? info.word ?? head,
                   phonetic: info.lemma?.phonetic.isEmpty == false ? info.lemma!.phonetic : (info.phonetic ?? ""),
                   definition: info.lemma?.translation ?? info.translation ?? [],
                   sentence: entry?.english ?? "",
                   sentenceZh: entry?.chinese ?? "",
                   morph: model.wordMorph)
        model.status = "已收藏「\(head)」到單字本（共 \(store.words.count) 個）"
    }

    /// 舊版收藏的字沒有字根拆解，伺服器就緒後補查
    private func backfillMorph() {
        let missing = store.wordsMissingMorph
        guard !missing.isEmpty else { return }
        Task {
            for w in missing {
                if let m = await dictionary.morph(w.word) {
                    store.setMorph(id: w.id, m)
                }
            }
            appLog("補上 \(missing.count) 個收藏單字的字根拆解")
        }
    }

    // MARK: - 手動修正原文

    private func beginEdit() {
        model.editText = model.english
        model.editing = true
        panel.allowsKeyboard = true
        panel.makeKey()  // 需要鍵盤輸入
    }

    private func submitEdit() {
        let text = TextNormalizer.normalize([model.editText])
        endEdit()
        guard !text.isEmpty else { return }
        lastText = text
        remember(text)
        startTranslation(text, force: true, ocrSeconds: nil)
    }

    private func endEdit() {
        model.editing = false
        panel.allowsKeyboard = false
        returnFocusToGame()
    }

    private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: - 紀錄

    private func appendHistory(english: String, chinese: String, seconds: Double, cached: Bool) {
        store.recordLine(english: english, chinese: chinese, model: TranslationCoordinator.modelName)
        let row: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "english": english, "chinese": chinese,
            "seconds": seconds, "cached": cached,
            "model": TranslationCoordinator.modelName,
            "crop": lastCropFile ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = AppPaths.history
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        }
    }

    /// 存下對話框截圖（之後可以對照 OCR 有沒有讀錯）；只保留最近 300 張
    private func saveCrop(_ image: CGImage) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = f.string(from: Date()) + ".png"
        let url = AppPaths.crops.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        if let files = try? FileManager.default.contentsOfDirectory(atPath: AppPaths.crops.path).sorted(),
           files.count > 300 {
            for old in files.prefix(files.count - 300) {
                try? FileManager.default.removeItem(at: AppPaths.crops.appendingPathComponent(old))
            }
        }
        return "crops/" + name
    }

    // MARK: - 選單列

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "GameLingo")

        let menu = NSMenu()
        serverMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        serverMenuItem.isEnabled = false
        menu.addItem(serverMenuItem)
        openEmuMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        openEmuMenuItem.isEnabled = false
        menu.addItem(openEmuMenuItem)
        permissionMenuItem = NSMenuItem(title: "⚠️ 開啟螢幕錄製權限設定…", action: #selector(openPermission), keyEquivalent: "")
        permissionMenuItem.target = self
        menu.addItem(permissionMenuItem)
        menu.addItem(.separator())

        menu.addItem(item("翻譯目前的對話　⌃⌥T", #selector(menuTranslate)))
        menu.addItem(item("重新翻譯　⌃⌥R", #selector(menuRetranslate)))
        menu.addItem(item("顯示／隱藏翻譯視窗　⌃⌥H", #selector(menuToggle)))
        autoMenuItem = item("自動翻譯（對話出現就翻）　⌃⌥A", #selector(menuAuto))
        menu.addItem(autoMenuItem)
        menu.addItem(.separator())
        reviewMenuItem = item("單字卡複習…", #selector(openReview))
        menu.addItem(reviewMenuItem)
        bookMenuItem = item("我的單字本…", #selector(openWordBook))
        menu.addItem(bookMenuItem)
        menu.addItem(.separator())
        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        menu.addItem(item("編輯名字清單（保留英文的名字）…", #selector(editNames)))
        menu.addItem(item("打開紀錄資料夾", #selector(openSupport)))
        menu.addItem(.separator())
        menu.addItem(item("結束 GameLingo", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func refreshMenu() {
        switch server.state {
        case .starting: serverMenuItem.title = "模型：啟動中…"
        case .unloaded: serverMenuItem.title = "模型：已卸載（OpenEmu 沒開，節省約 8 GB 記憶體）"
        case .loading: serverMenuItem.title = "模型：載入中…"
        case .ready: serverMenuItem.title = "模型：就緒（Seed-X 8-bit）"
        case .failed(let msg): serverMenuItem.title = "模型：錯誤（\(msg.split(separator: "\n").first ?? "")）"
        }
        if server.state == .ready, model.status.hasPrefix("模型") || model.status.hasPrefix("載入翻譯模型") {
            model.status = autoEnabled ? "就緒：對話出現就會自動翻譯（⌃⌥A 關閉）" : "就緒：在遊戲中按 ⌃⌥T 翻譯對話"
        }
        if server.state == .unloaded, model.status.hasPrefix("模型") {
            model.status = "模型已卸載以節省記憶體；開 OpenEmu 會自動載入"
        }
        autoMenuItem.state = autoEnabled ? .on : .off
        if case .failed(let msg) = server.state {
            model.status = msg
        }
        openEmuMenuItem.title = isOpenEmuRunning ? "OpenEmu：執行中" : "OpenEmu：未開啟"
        permissionMenuItem.isHidden = Permissions.hasScreenCapture
    }

    private func observeOpenEmu() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == CaptureService.openEmuBundleID else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshMenu()
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        // 開遊戲：取消待卸載，馬上載入模型
                        self.unloadTask?.cancel()
                        self.server.load()
                    } else if AppSettings.releaseMemory {
                        // 關遊戲：等一下再卸載（避免只是重開 OpenEmu 就卸載又載入）
                        self.unloadTask?.cancel()
                        let delay = AppSettings.releaseDelay
                        self.unloadTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard let self, !Task.isCancelled, !self.isOpenEmuRunning else { return }
                            self.server.unload()
                        }
                    }
                }
            }
        }
    }

    @objc private func menuTranslate() { translateCurrent(force: false) }
    @objc private func menuRetranslate() { translateCurrent(force: true) }
    @objc private func menuToggle() { togglePanel() }
    @objc private func menuAuto() { setAuto(!autoEnabled, announce: true) }
    @objc private func openPermission() { Permissions.openScreenCaptureSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openSettings() { settingsWindow.show() }

    @objc private func editNames() {
        _ = KnownNames.load()
        NSWorkspace.shared.open([AppPaths.knownNames],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openSupport() { NSWorkspace.shared.open(AppPaths.support) }
    @objc private func openReview() { studyWindows.showReview() }
    @objc private func openWordBook() { studyWindows.showWordBook() }

    private func refreshStudyMenu() {
        let due = store.dueCount
        reviewMenuItem?.title = due > 0 ? "單字卡複習（今天 \(due) 張）…" : "單字卡複習（今天沒有到期的卡）…"
        bookMenuItem?.title = "我的單字本（\(store.words.count) 個）…"
        statusItem?.button?.title = due > 0 ? " \(due)" : ""
        statusItem?.button?.imagePosition = .imageLeading
    }
}
