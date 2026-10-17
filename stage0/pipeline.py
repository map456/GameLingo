"""完整流程試跑：截圖 → 找對話框 → OCR（多尺寸投票）→ 專名保護 → Seed-X 翻譯 → 台灣正體。

用法（在 stage0 資料夾裡）：
    uv run python pipeline.py samples/*.png      # 翻譯指定的截圖檔
    uv run python pipeline.py --watch            # 每 1 秒看一次 OpenEmu 視窗，有新對話就翻譯（Ctrl+C 結束）

--watch 需要「螢幕錄製」權限：系統設定 → 隱私權與安全性 → 螢幕與系統錄音 → 打開「終端機」。
每句結果會附加到 out/live_log.jsonl，之後可以拿來做報表。
"""

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

from common import find_dialog_box, ocr_ensemble
from translate_test import HF_MODEL, MLX_8BIT_DIR, PROMPT, MLXBackend, protect, restore, s2twp

HERE = Path(__file__).parent
LOG = HERE / "out" / "live_log.jsonl"
CROPS_DIR = HERE / "out" / "live_crops"


# ---------- 找 OpenEmu 遊戲視窗並截圖 ----------

def find_openemu_window():
    """回傳 OpenEmu 遊戲視窗的編號。NDS 上下排列時視窗是直的，用這點跟遊戲庫視窗區分。"""
    import Quartz

    wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID)
    cands = []
    for w in wins:
        if w.get("kCGWindowOwnerName") != "OpenEmu" or w.get("kCGWindowLayer") != 0:
            continue
        if w.get("kCGWindowAlpha", 1) == 0:
            continue
        b = w["kCGWindowBounds"]
        if b["Width"] < 200 or b["Height"] < 200:
            continue
        cands.append((b["Height"] / b["Width"], w["kCGWindowNumber"]))
    if not cands:
        return None
    cands.sort(reverse=True)  # 最「直」的那個就是遊戲視窗
    return cands[0][1]


def capture_window(win_id) -> Image.Image | None:
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        path = f.name
    r = subprocess.run(["screencapture", "-x", "-o", "-l", str(win_id), path], capture_output=True)
    if r.returncode != 0:
        return None
    img = Image.open(path)
    img.load()
    Path(path).unlink(missing_ok=True)
    return img


# ---------- 翻譯 ----------

class Translator:
    def __init__(self, model):
        path = MLX_8BIT_DIR if model == "8bit" else HF_MODEL
        if model == "8bit" and not MLX_8BIT_DIR.exists():
            print("找不到 8-bit 模型，改用原版 BF16")
            path = HF_MODEL
        print(f"載入模型 {path} …", flush=True)
        self.be = MLXBackend(path)
        self.be.generate(PROMPT.format(text="Hello."), max_tokens=8)  # 預熱
        self.cache = {}

    def translate(self, text):
        if text in self.cache:
            return self.cache[text], 0.0, []
        guarded, names = protect(text)
        raw, m = self.be.generate(PROMPT.format(text=guarded))
        zh, missing = restore(s2twp.convert(raw), names)
        if missing:
            # 佔位符被模型弄丟 → 改成不保護直接翻（專名會變音譯，但至少句子完整）
            raw, m2 = self.be.generate(PROMPT.format(text=text))
            zh = s2twp.convert(raw)
            m["total_s"] += m2["total_s"]
        self.cache[text] = zh
        return zh, m["total_s"], missing


def process(img, tr: Translator, source: str):
    t0 = time.perf_counter()
    box = find_dialog_box(img, fallback=False)
    if box is None:
        print(f"\n[{source}] 畫面上沒有找到對話框，略過", flush=True)
        return None
    crop = img.crop(box)
    text, _ = ocr_ensemble(crop)
    t_ocr = time.perf_counter() - t0
    if not text:
        return None
    zh, t_tr, missing = tr.translate(text)
    total = time.perf_counter() - t0
    row = {"time": time.strftime("%H:%M:%S"), "source": source, "ocr": text, "zh": zh,
           "ocr_s": round(t_ocr, 2), "translate_s": round(t_tr, 2), "total_s": round(total, 2),
           "placeholder_lost": missing}
    print(f"\n[{row['time']}] {text}\n  → {zh}\n  （OCR {t_ocr:.2f}s＋翻譯 {t_tr:.2f}s＝{total:.2f}s）", flush=True)
    LOG.parent.mkdir(exist_ok=True)
    if source == "live":
        # 存下這句的對話框截圖，之後可以拿來對照 OCR 有沒有漏字
        CROPS_DIR.mkdir(parents=True, exist_ok=True)
        name = time.strftime("%Y%m%d-%H%M%S") + ".png"
        crop.save(CROPS_DIR / name)
        row["crop"] = f"live_crops/{name}"
    with LOG.open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return row


def is_repeat(text, recent):
    """跟最近 5 句幾乎一樣（相似度 ≥ 0.9）就當成同一句。
    例外：新的字比較長、而且是舊的加長版（逐字顯示打完了），要重翻。"""
    from difflib import SequenceMatcher

    for r in recent:
        if SequenceMatcher(None, text, r).ratio() >= 0.9 and len(text) <= len(r) + 3:
            return True
    return False


def watch(tr: Translator, interval: float):
    win = find_openemu_window()
    if win is None:
        sys.exit("找不到 OpenEmu 遊戲視窗。請先開啟 OpenEmu 並開始遊戲（視窗模式）。")
    print("開始監看 OpenEmu（Ctrl+C 結束）。對話出現並停住約 1 秒後會自動翻譯。", flush=True)
    last_seen = None
    recent = []  # 最近翻過的句子，用來擋掉「OCR 差一兩個字」造成的重複翻譯
    while True:
        img = capture_window(win)
        if img is None:
            win = find_openemu_window()
            if win is None:
                sys.exit("OpenEmu 視窗不見了。")
            img = capture_window(win)
            if img is None:
                sys.exit("無法截取視窗畫面。請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」"
                         "打開「終端機」的權限，然後完全結束終端機再重開。")
        box = find_dialog_box(img, fallback=False)
        text = ocr_ensemble(img.crop(box))[0] if box else ""  # 沒有對話框就不辨識
        # 連續兩次讀到一樣的字才翻（避免逐字顯示時翻到一半的句子）
        if text and len(text) > 3 and text == last_seen and not is_repeat(text, recent):
            process(img, tr, "live")
            recent = (recent + [text])[-5:]
        last_seen = text
        time.sleep(interval)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*", help="截圖檔")
    ap.add_argument("--watch", action="store_true", help="持續監看 OpenEmu 視窗")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--model", choices=["8bit", "bf16"], default="8bit")
    args = ap.parse_args()
    if not args.images and not args.watch:
        ap.print_help()
        return

    tr = Translator(args.model)
    for p in args.images:
        process(Image.open(p), tr, p)
    if args.watch:
        try:
            watch(tr, args.interval)
        except KeyboardInterrupt:
            print("\n結束。紀錄在", LOG)


if __name__ == "__main__":
    main()
