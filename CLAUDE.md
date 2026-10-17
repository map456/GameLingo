# GameLingo：OpenEmu 英文遊戲翻譯與單字學習助手

## 專案目標

一個 macOS 常駐小工具：玩 OpenEmu 上的英文遊戲時，按快捷鍵擷取對話框 → 本機 OCR → 本機模型翻譯成繁體中文 → 浮動視窗中英對照顯示；可點單字查詢、收藏，並用單字卡複習。全程本機執行，不修改 OpenEmu 或 ROM。

## 使用者與協作方式（重要）

- 使用者**沒有 Xcode 與 Swift 經驗**。請寫完整、可直接執行的程式，不要留「請自行補上」的部分。
- 每一步都用繁體中文（台灣用語）說明：要在終端機輸入什麼、要點哪裡、預期看到什麼。
- 需要使用者動手的事（安裝 Xcode、授權螢幕錄製、截圖）要明確列出步驟。
- 一次只做一個階段；每個階段結束先請使用者實測，通過關卡再往下。

## 已確定的條件

| 項目 | 決定 |
| --- | --- |
| 硬體 | Apple M5 Max，記憶體 64GB（`sysctl hw.memsize` 實測） |
| 遊戲 | NDS《Dragon Quest IV: Chapters of the Chosen》英文版 |
| 模擬器 | OpenEmu，視窗模式（不用全螢幕），NDS 雙螢幕**上下排列** |
| 翻譯模型 | Seed-X-PPO-7B（ByteDance） |
| 名詞表 | 不建立；專有名詞直接顯示英文原文 |
| 遊戲用語替換 | 不做（例如不把 party 換成 team 再送模型）；接受「黨內同志」這類語境錯誤（2026-10-16 決定） |
| 語境解說 | 試 Seed-X 官方「翻譯並詳細解說」寫法，點按時才產生 |
| 複習 | 自己做，只做單字卡（SM-2 排程），不依賴 Anki |
| 顯示 | 獨立浮動視窗，不搶鍵盤焦點 |

## 架構

```
OpenEmu 視窗 ──畫面──▶ 擷取層 ──▶ 辨識層 ──▶ 翻譯層 ──▶ 浮動視窗
                        ▲                      │            │
          殼層（快捷鍵觸發）           本機模型伺服器      學習層 ──▶ 本機 SQLite
                                   （mlx_lm.server 或 Ollama）
```

| 元件 | 層 | 職責 | 技術 | 版本 |
| --- | --- | --- | --- | --- |
| AppCoordinator | 殼層 | 選單列常駐、偵測 OpenEmu 啟動與結束、預熱模型、檢查權限 | `NSWorkspace` 通知、`LSUIElement` | v1 |
| HotkeyService | 殼層 | 全域快捷鍵：翻譯、重新翻譯、收藏、隱藏視窗 | KeyboardShortcuts 套件或 Carbon `RegisterEventHotKey`（不需輔助使用權限） | v1 |
| CaptureService | 擷取 | 擷取 OpenEmu 視窗；手動單張、自動模式低幀率串流 | ScreenCaptureKit（`SCScreenshotManager`、`SCStream`） | v1 |
| RegionStore | 擷取 | 記住對話框位置，以「螢幕排列＋視窗比例」儲存 | SwiftUI 框選介面 | v1 |
| DialogueDetector | 擷取 | 判斷文字打完、換頁 | 縮圖灰階雜湊比對＋穩定時間 | v2 |
| Preprocessor | 辨識 | 裁切、最近鄰放大 2～3 倍、灰階／二值化 | Core Image / vImage | v1 |
| OCRService | 辨識 | 英文辨識 | Apple Vision `VNRecognizeTextRequest`（accurate） | v1 |
| TextNormalizer | 辨識 | 去說話者標記（如 `*:`）、翻頁符號、合併斷行 | 規則與正規表示式 | v1 |
| TranslationCoordinator | 翻譯 | 查快取、取消舊任務、只處理最新一句 | Swift Concurrency（actor + Task 取消） | v1 |
| ProperNounGuard | 翻譯 | 翻譯前把專有名詞換成佔位符（如 `⟦1⟧`），翻譯後還原英文 | 大寫詞規則＋已見名詞清單 | v1 |
| LLMProvider / SeedXProvider | 翻譯 | 統一模型介面；套用 Seed-X 固定提示格式 | HTTP 呼叫本機伺服器 | v1 |
| ChineseConverter | 翻譯 | 輸出統一成台灣正體與慣用詞 | OpenCC `s2twp` | v1 |
| DictionaryService | 學習 | 詞形還原、音標、詞性、中文釋義 | ECDICT（SQLite）、`NLTagger` | v1 |
| SpeechService | 學習 | 單字與整句發音 | `AVSpeechSynthesizer` | v1 |
| StudyStore | 學習 | 收藏、翻譯歷史、單字卡排程 | SQLite（GRDB） | v1 收藏，v2 複習 |
| OverlayPanel | UI | 浮動視窗，可拖曳並記住位置 | 不啟用焦點的 `NSPanel`，層級 floating | v1 |

最低支援 macOS 14（`SCScreenshotManager` 需要）。

### 階段 1 實作上的調整（2026-10-16）

- **翻譯層放在 Python 伺服器**（`server/gamelingo_server.py`）：ProperNounGuard、SeedXProvider、ChineseConverter 都在這裡。原因是 OpenCC 在 Swift 要另外編 C++ 函式庫，Python 版階段 0 已驗證。App 啟動時自動在背景啟動伺服器（port 8765），結束時一起關掉。API：`POST /translate` 回傳 NDJSON 串流，新請求會自動取消舊的。不用 `mlx_lm.server`。
- **模型**：自己用 `mlx_lm.convert` 轉的 MLX 8-bit（`models/seedx-mlx-8bit`），greedy（溫度 0）。
- **RegionStore 先不做框選**：自動偵測 DQ4 白色對話框外框（`DialogBoxFinder`），找不到外框就不辨識。換其他遊戲或偵測失準時再加框選。
- **OCR**：二值化 → 5 種寬度各跑一次 Vision → 逐字投票（`OCRService`），與階段 0 結果一致。
- **快取**：v1 先放記憶體；翻譯歷史寫 `~/Library/Application Support/GameLingo/history.jsonl`，SQLite（GRDB）留到階段 2。
- **快捷鍵**：⌃⌥T 翻譯、⌃⌥R 重新翻譯（不查快取）、⌃⌥H 顯示／隱藏、⌃⌥A 自動翻譯開關。「收藏」留到階段 2。
- **擷取方式**：不用 ScreenCaptureKit。實測每 0.7 秒呼叫 SCShareableContent＋SCScreenshotManager 會讓 OpenEmu **收不到鍵盤按鍵**；改用 `CGWindowListCopyWindowInfo` 找視窗＋`/usr/sbin/screencapture -x -o -l <視窗ID>` 截圖（階段 0 驗證過不影響按鍵）。
- **自動偵測提前到階段 1**（使用者要求）：每 1 秒擷取一次；對話框 128×32 黑白縮圖指紋沒變就不重跑 OCR；文字連續兩次相同才翻；與最近 5 句相似度 ≥ 0.9 不重翻。預設開啟，選單列可關。
- **screencapture 暫存檔**：要先把整個檔讀進記憶體再解碼（`CGImageSourceCreateWithData`），直接從檔案建 CGImageSource 再刪檔會拿到空白圖。
- **有名字標籤的對話框**（如「King Burnard」框疊在主框上）也偵測得到；OCR 只讀主框，口音拼寫（Hoo、oor、disappearin'）會原樣保留。
- **非名字的口音字**：Hoo、Oor、Cannae 等加入伺服器的 NOT_NAMES，避免句首大寫被當成名字保留英文。
- **浮動視窗改成累積清單**（使用者要求）：每句接在下面，最多 100 句，自動捲到最新。
- **點字查詢提前到階段 1**（使用者要求）：英文單字做成連結，點了查 ECDICT。字典由伺服器 `GET /lookup?word=` 查（`data/ecdict.db`，由 `ecdict.csv` 經 `server/build_dict.py` 轉成，約 77 萬詞條），釋義經 OpenCC 轉台灣正體；處理 -in'→-ing、所有格，並用 exchange 欄位找原形。發音用 AVSpeechSynthesizer。收藏與單字卡仍在階段 2。
- **階段 2 實作（2026-10-16）**：`Study/` 用系統 libsqlite3（薄包裝 `SQLiteDB`，不用 GRDB）。`study.sqlite` 有 lines、saved_words（以原形為唯一鍵，記 form、音標、釋義、原句與翻譯）、cards（SM-2：q 忘記1/困難3/普通4/簡單5，1→6→×EF，忘記歸零且同輪再考）。字卡「☆ 收藏」存原形；已收藏字在句子中黃底。選單列：單字卡複習、我的單字本，圖示旁顯示到期張數。啟動時從 lines 帶回最近 30 句，第一次會匯入 history.jsonl。
- **克漏字卡與字根拆解（2026-10-16，使用者要求）**：`review_cards(saved_word_id, kind)` 取代 v1 的 `cards`（啟動時自動搬移並刪除舊表），kind＝meaning／cloze，各自 SM-2；原句含該字才有克漏字卡（首字母＋底線，附中文翻譯提示）；同一字的兩張卡盡量不連續出。`saved_words.morph` 存拆解 JSON，舊收藏在伺服器就緒後自動補查。拆解來自 `data/morph.db`：MorphoLex-en（6.8 萬字，`<dis<(appear)>ance>` 格式，CC BY-NC-SA 4.0 限非商業）＋ ECDICT wordroot.txt（611 條，key 如「-ance, -ence」「in-1」需展開變體）；188 條字首字尾中文為人工校對（`server/affix_zh.json`），423 條字根用 Seed-X 翻（快取 `data/wordroot_zh.json`）；字根本身是英文字時改用 ECDICT 釋義；同家族例字排除純變化形（segm＝`{(root)}`）。伺服器 `GET /morph?word=`。
- **不玩時釋放記憶體（2026-10-17）**：伺服器可 `--lazy` 啟動（約 50 MB，只做字典／字根查詢）、`POST /load`、`POST /unload`（卸載後約 150 MB，載回約 1～5 秒），翻譯請求會自動載回。App 端 ModelServer 狀態 starting／unloaded／loading／ready／failed；OpenEmu 啟動就 load，關閉後依設定延遲 unload；按翻譯時 `ensureModel()` 會先等模型載好。
- **語境解說（2026-10-17，階段 3）**：伺服器 mode=explain 用 Seed-X 官方「翻譯並詳細解說」提示、溫度 0.7，沒產生 [COT] 就重試（最多 3 次），回傳 `zh` 與 `explanation`，並刪掉開頭「好的，我現在需要…使用者…」與結尾「總結一下…」的自言自語段落。約 14 秒。翻譯視窗每句有 💡 按鈕，解說顯示在該句下方黃色區塊，同句有記憶體快取。job 取消改成「同模式」才互相取消（新翻譯不會中斷進行中的解說）。
- **設定視窗（2026-10-17）**：`AppSettings`（UserDefaults key）＋ `SettingsView`（@AppStorage）：自動翻譯與間隔、中英文字級、不透明度、釋放記憶體與延遲、登入時啟動（SMAppService）、名字清單編輯、快捷鍵一覽。
- **App 圖示**：使用者提供的圖，去白底、依 Apple 留白比例置中，`GameLingo/Resources/AppIcon.icns`，build.sh 複製到 bundle。
- **翻譯視窗配色**：每句圓角色塊（英文深色帶＋中文），最新一句藍框；字卡橘色。
- **選單過濾**：自動模式遇到 2 個以上「100G」「x 1」這類價格／數量就當商店選單不翻（⌃⌥T 仍可手動翻）。
- **模型亂寫解說**：一般翻譯模式下，伺服器遇到「[COT]」、空行或「（注」就停止生成並截斷。
- **專名規則**：`[A-Z][a-z]+` 後可接大寫段落，McRyan 這類名字才會整個保護。
- **名字清單**：`~/Library/Application Support/GameLingo/known_names.txt`（預設含主角名 Xi），一律保護。
- **編譯**：不開 Xcode，用 SwiftPM ＋ `build.sh` 打包成 `build/GameLingo.app`，以使用者的 Apple Development 憑證簽章（簽章固定，重新編譯後螢幕錄製權限不會失效）。`GameLingo --ocr-test 圖.png` 可在命令列測 OCR。

## 處理流程（快捷鍵模式）

1. 快捷鍵 → 擷取 OpenEmu 視窗一張。
2. 依 RegionStore 裁出對話框（上下排列時通常在上方螢幕底部）。
3. 前處理 → Vision OCR → 文字清理；空字串或與上一句相同就結束。
4. 查快取（鍵＝清理後文字＋模型名稱＋prompt 版本），命中立即顯示。
5. 未命中：取消舊任務 → ProperNounGuard 換佔位符 → 以 Seed-X 格式送出**單句**（不帶上下文）。
6. 串流輸出每次更新都對整段重跑 OpenCC（避免詞被切斷轉錯）→ 還原佔位符 → 顯示。
7. 寫入快取與翻譯歷史。

點單字：先查 ECDICT（即時）；語境解說點按才送 Seed-X。

## Seed-X-PPO-7B 串接要點（必須遵守）

來源：https://huggingface.co/ByteDance-Seed/Seed-X-PPO-7B

- **沒有 chat template、不支援多輪對話**，提示句結尾**必須**加目標語言標籤 `<zh>`。
- 用 Ollama 時走 `/api/generate` 並設 `raw: true`；用 `mlx_lm.server` 時走 completions 端點，不要用 chat 端點。
- 目標語言只有 `zh`（不分繁簡）→ OpenCC `s2twp` 是必要步驟。
- 官方建議 beam search（寬度 4），也提供 greedy（溫度 0）。Ollama 無 beam search，用溫度 0。
- 官方**不建議非官方量化版**。以 MLX 跑原版 BF16（約 16GB）為品質基準；社群 GGUF 或 MLX 8-bit 只作速度對照，品質相當才採用。
- 授權：OpenMDW。

翻譯：
```
Translate the following English sentence into Chinese:
But dusk draws inexorably closer. We will commence the lesson tomorrow. <zh>
```

翻譯並解說（語境解說用）：
```
Translate the following English sentence into Chinese and explain it in detail:
But dusk draws inexorably closer. We will commence the lesson tomorrow. <zh>
```

## 資料模型（SQLite）

| 資料表 | 主要欄位 | 用途 |
| --- | --- | --- |
| games | id、名稱、對話框區域（螢幕排列＋比例座標） | 遊戲設定 |
| lines | id、game_id、英文原句、中文翻譯、模型、時間 | 翻譯歷史 |
| saved_words | id、單字原形、出現時詞形、line_id、備註、時間 | 收藏單字 |
| cards | saved_word_id、下次複習日、間隔天數、難易係數、連續答對次數 | SM-2 排程 |
| proper_nouns | 英文原文、首次出現 line_id | 已見過的專有名詞 |
| translation_cache | 快取鍵、譯文、建立時間 | 避免重複翻譯 |

ECDICT 另存唯讀檔，與個人資料分開。

單字卡：正面＝單字＋音標＋遊戲原句（該字加底線，可發音）；背面＝詞性、釋義、整句翻譯；作答「忘記／困難／普通／簡單」交給 SM-2；選單列顯示今日待複習數，不在遊玩時跳出。

## 專案結構（Swift App，階段 1 起）

實際結構（階段 1）：`GameLingo/Sources/GameLingo/{App,Capture,Recognition,Translation,UI}`、`server/`、`models/`、`build.sh`。下面是原始規劃，Dictionary、Study 等在階段 2 起加入。

```
GameLingo/
├── App/            AppCoordinator、選單列、權限檢查
├── Capture/        CaptureService、RegionStore、DialogueDetector
├── Recognition/    Preprocessor、OCRService、TextNormalizer
├── Translation/    TranslationCoordinator、LLMProvider、SeedXProvider、
│                   ProperNounGuard、ChineseConverter、TranslationCache
├── Dictionary/     DictionaryService、Lemmatizer、SpeechService
├── Study/          StudyStore、CardScheduler（SM-2）、ReviewSession
├── UI/             OverlayPanel、TranslationView、WordDetailView、
│                   RegionPickerView、FlashcardView、SettingsView
└── Resources/      ecdict.sqlite
```

## 開發階段與關卡

| 階段 | 內容 | 通過關卡 |
| --- | --- | --- |
| 0 驗證（Python 腳本） | `ocrmac` 跑 Vision OCR、`mlx-lm` 跑 Seed-X；比較 MLX BF16 與 Ollama GGUF；量延遲 | OCR 可用、譯文可讀、短句 3 秒內 |
| 1 基本翻譯（Swift） | 快捷鍵擷取與框選、OCR 清理、Seed-X 翻譯與保留專名、浮動視窗中英對照 | 實玩一小時不卡、不打斷操作 ✅ 2026-10-16 使用者實測通過 |
| 2 學習 | 點字查詢與發音、ECDICT 釋義、收藏、單字卡基本版 | 收藏流程順手（2026-10-16 已實作，含 SM-2，待實測） |
| 3 自動與複習 | 自動偵測對話、SM-2 排程、Seed-X 語境解說 | —（2026-10-17 全部實作） |

關卡沒過就回頭調整（OCR 不穩先改前處理；譯文不好再評估模型），不要帶著問題進下一階段。

## 階段 0 待驗證清單

- [x] Vision 辨識 DQ4 對話框正確率 → 單一設定不穩（像素字 a 常被認成 o，尺寸差一點結果就變）。採用「二值化＋縮到固定寬度＋四周留白」並用 5 種寬度（400/440/480/520/680）逐字投票、語言校正開，模擬 6 種視窗大小 24/24 全對，約 0.25 秒。口音拼寫句仍需實際截圖驗證
- [x] Seed-X 翻譯 DQ4 原句品質 → 使用者看 `stage0/out/report.html` 判斷，12 句全標「好」（mock-noun-2 未判斷）。已知問題：缺遊戲語境，「party」一律翻成政黨／聚會，「save thy progress」翻成學習進度；使用者決定接受、不做用語替換。真實遊戲台詞（含口音）待 `--watch` 實測補驗
- [x] MLX 原版 BF16 與 Ollama 社群 GGUF 比較 → Ollama GGUF（mradermacher Q8_0）會失控重複或答非所問，**不採用**。自己用 `mlx_lm.convert` 轉的 MLX 8-bit 譯文與 BF16 幾乎相同，快約 40%，記憶體 8 GB（BF16 15 GB）
- [x] 短句翻譯延遲 → BF16 中位數 0.6 秒、8-bit 0.4 秒；含 OCR 全流程約 0.9 秒
- [x] 專有名詞佔位符 → `⟦1⟧`、`#1`、`{1}`、`<1>` 會讓模型加「號」或自己寫註解；`NAME1` 在呼喚語（「now, Xi.」「Xi! Wake up」）會變「姓名1號」；**`X1`、`X2` 7 種句型全部原樣保留，採用**。偵測到遺失就改用不保護的直接翻譯
- 主角名字是玩家自取（使用者取名 Xi），字典裡剛好有 xi → 實玩被翻成「習同志」。用 `stage0/known_names.txt` 列出一律保護的名字；Swift 版要在設定裡讓使用者填主角名
- [x] 「翻譯並詳細解說」→ greedy／beam 只會翻譯不解說；要用溫度 0.7 取樣，且不一定每次都有。有解說時會在「[COT]」後面詳細說明方言、用字，約 600 tokens
- [x] 遊戲與模型同時執行的記憶體壓力（實測硬體是 64GB）→ 8-bit 模型＋OpenEmu 同時跑，系統可用記憶體仍 61%，無壓力
- [x] 實玩（`pipeline.py --watch`，約 2 分鐘、12 句真實台詞）→ 譯文通順，全流程 0.6～1.6 秒。發現並修正：沒對話框時誤讀地圖紋理（改為找不到外框就跳過）、同一句因 OCR 小差異重複翻譯（與最近 5 句相似度 ≥ 0.9 就略過）、開頭多讀到 `*`。未解：一句開頭疑似漏字（「not give up.」）、一句尾巴多出「• ca... •」、「Mrim」疑似「Mmm」誤讀——當時沒存截圖無法確認，階段 1 用手動快捷鍵擷取可避開逐字顯示問題，再觀察

其他實測發現：
- Seed-X 輸出開頭會有 `<s>`（模型自己產生的），要濾掉特殊符號。
- mlx-lm 沒有 beam search，自己寫在 `stage0/beam.py`；beam 4 跟 greedy 差異很小，延遲多約 0.2 秒。
- 字典 `/usr/share/dict/words` 的大寫字含人名（裡面有 Ragnar），判斷專名時只能用小寫字。

階段 0 產出：測試腳本、對照報表（原文／OCR 結果／譯文／耗時），讓使用者逐句判斷。說明見 `stage0/README.md`。

## 主要風險

- 像素字 OCR 誤判 → 前處理調參；浮動視窗允許手動修正原文後重翻。
- Seed-X 不吃額外指示與上下文 → 雙關、文謅謅台詞無法靠 prompt 補救，以實測判斷。
- 模型輸出簡體或中國用語 → OpenCC `s2twp`。
- 逐字顯示時太早翻譯 → v1 用手動快捷鍵避開；v2 用穩定時間判斷。
- 浮動視窗搶焦點 → 不啟用焦點的 `NSPanel`。
