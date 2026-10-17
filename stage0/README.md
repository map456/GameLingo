# 階段 0：驗證（Python 腳本）

目的：在寫 Swift App 之前，先確認「截圖 → OCR → Seed-X 翻譯」這條路可行，並找出問題。

## 檔案說明

| 檔案 | 做什麼 |
| --- | --- |
| `samples/` | 測試用截圖（你放的 4 張）；`answers.json` 是每張圖的正確原文 |
| `common.py` | 找對話框、前處理、Vision OCR、多尺寸投票、文字清理 |
| `ocr_test.py` | 比較各種前處理 × 語言校正開關的 OCR 正確率 |
| `translate_test.py` | 用不同後端跑 Seed-X，量速度、測專名佔位符、測「翻譯並解說」 |
| `beam.py` | 自己實作的 beam search（mlx-lm 沒有內建） |
| `pipeline.py` | 完整流程試跑；`--watch` 可以邊玩邊自動翻譯 |
| `make_report.py` | 產生 `out/report.html` 對照報表 |
| `models/` | 自己轉的 MLX 8-bit 模型（約 7.4 GB） |

原版模型（約 15 GB）在 `~/.cache/huggingface/hub/`。

## 怎麼用

以下指令都在「終端機」App 裡輸入。先進到這個資料夾：

```bash
cd ~/Desktop/git/openemu-translate/stage0
```

### 1. 看對照報表，逐句判斷

```bash
open out/report.html
```

會用瀏覽器打開。每一句選「好／可以／看不懂／錯誤」，有問題的寫備註，最後按最下面「複製我的判斷」，貼回給 Claude。

### 2. 邊玩邊翻譯（實測）

第一次要先給終端機「螢幕錄製」權限：

1. 打開「系統設定」→「隱私權與安全性」→「螢幕與系統錄音」。
2. 找到「終端機」並打開開關（沒有的話按 `+` 加入「應用程式 → 工具程式 → 終端機」）。
3. **完全結束終端機（⌘Q）再重新打開**，權限才會生效。

然後：

1. 打開 OpenEmu，用視窗模式開始玩 DQ4。
2. 在終端機輸入：

   ```bash
   uv run python pipeline.py --watch
   ```

3. 預期看到「載入模型…」，接著是「開始監看 OpenEmu」。
4. 回到遊戲正常玩。每當對話框文字停住約 1 秒，終端機就會印出英文原文、中文翻譯和耗時。
5. 玩完在終端機按 `Ctrl+C` 結束。所有句子會存到 `out/live_log.jsonl`，請把這個檔案交給 Claude 分析。

> 這只是驗證用：翻譯顯示在終端機，不是最後的浮動視窗。

### 3. 重跑測試（有新截圖時）

把截圖放進 `samples/`，在 `samples/answers.json` 補上正確原文，然後：

```bash
uv run python ocr_test.py
uv run python translate_test.py --backend mlx-bf16
uv run python translate_test.py --backend mlx-8bit
uv run python make_report.py
```
