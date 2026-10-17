"""階段 0 共用工具：找對話框、前處理、Vision OCR、文字清理。"""

import re

import numpy as np
import objc
import Vision
from ocrmac.ocrmac import pil2buf
from PIL import Image, ImageOps


# ---------- 找對話框 ----------

def find_dialog_box(img: Image.Image, fallback=True):
    """在畫面下半部找 DQ4 對話框的白色外框，回傳框內區域 (left, top, right, bottom)。

    做法：對每一列計算「接近白色的像素比例」，外框的上下兩條橫線比例會特別高。
    找不到時：fallback=True 退回「畫面最下方 20%」；fallback=False 回傳 None
    （邊玩邊監看時用，避免把地圖紋理誤認成文字）。
    """
    rgb = np.asarray(img.convert("RGB")).astype(np.int16)
    h, w, _ = rgb.shape
    white = (rgb.min(axis=2) > 200)
    row_ratio = white.mean(axis=1)

    start = int(h * 0.5)
    rows = [y for y in range(start, h) if row_ratio[y] > 0.6]
    if len(rows) >= 2:
        # 把相鄰的列合併成「線」
        lines = []
        for y in rows:
            if lines and y - lines[-1][-1] <= 3:
                lines[-1].append(y)
            else:
                lines.append([y])
        if len(lines) >= 2:
            top = lines[0][-1] + 1
            bottom = lines[-1][0]
            if bottom - top > h * 0.05:
                # 左右邊框：在框內的範圍找白色比例高的欄
                col_ratio = white[top:bottom].mean(axis=0)
                cols = [x for x in range(w) if col_ratio[x] > 0.6]
                left = (max([x for x in cols if x < w / 2], default=-1)) + 1
                right = min([x for x in cols if x > w / 2], default=w)
                pad = 4
                return (left + pad, top + pad, right - pad, bottom - pad)
    return (0, int(h * 0.8), w, h) if fallback else None


# ---------- 前處理 ----------

def prep_raw(img):
    return img.convert("RGB")


def prep_gray(img):
    return ImageOps.grayscale(img)


def prep_binary(img, threshold=190):
    """DQ4 的字是白色：三個顏色通道都很亮才算字。輸出白底黑字。"""
    rgb = np.asarray(img.convert("RGB"))
    mask = rgb.min(axis=2) > threshold
    out = np.where(mask, 0, 255).astype(np.uint8)
    return Image.fromarray(out, mode="L")


def prep_binary_down(img, threshold=190):
    """二值化後縮小一半：截圖本身已被放大，太大的像素字反而可能干擾辨識。"""
    b = prep_binary(img, threshold)
    return b.resize((b.width // 2, b.height // 2), Image.Resampling.LANCZOS)


def prep_best(img, threshold=190, target_width=480, margin=60):
    """推薦做法：二值化 → 縮到固定寬度 → 四周加白邊。

    實測發現 Vision 對「字貼著圖片邊緣」很敏感，會把像素字的 a 認成 o；
    四周留白之後幾乎全對。縮到固定寬度讓不同視窗大小的截圖都有一致的字高。
    """
    b = prep_binary(img, threshold)
    scale = target_width / b.width
    b = b.resize((target_width, max(1, int(b.height * scale))), Image.Resampling.LANCZOS)
    return ImageOps.expand(b, border=margin, fill=255)


PREPROCESSORS = {
    "raw": prep_raw,
    "gray": prep_gray,
    "binary": prep_binary,
    "binary_half": prep_binary_down,
    "best": prep_best,
}


# ---------- Vision OCR ----------

def vision_ocr(img: Image.Image, language_correction: bool):
    """呼叫 Apple Vision VNRecognizeTextRequest（accurate）。回傳由上到下排好的行。"""
    with objc.autorelease_pool():
        req = Vision.VNRecognizeTextRequest.alloc().init()
        req.setRecognitionLevel_(0)  # 0 = accurate
        req.setRecognitionLanguages_(["en-US"])
        req.setUsesLanguageCorrection_(language_correction)
        handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(pil2buf(img), None)
        handler.performRequests_error_([req], None)
        lines = []
        for r in req.results() or []:
            cand = r.topCandidates_(1)[0]
            box = r.boundingBox()
            lines.append((box.origin.y, str(cand.string()), float(cand.confidence())))
    # Vision 座標原點在左下，y 大的在上面
    lines.sort(key=lambda t: -t[0])
    return [(t, c) for _, t, c in lines]


# ---------- 多尺寸投票 ----------

ENSEMBLE_WIDTHS = (400, 440, 480, 520, 680)
_WORDS = None


def _english_words():
    """macOS 內建英文單字表，只用來在票數相同時挑「是真的英文字」的那個。"""
    global _WORDS
    if _WORDS is None:
        try:
            with open("/usr/share/dict/words") as f:
                _WORDS = {w.strip().lower() for w in f}
        except OSError:
            _WORDS = set()
    return _WORDS


def _is_word(token: str) -> bool:
    core = re.sub(r"[^A-Za-z']", "", token).lower().strip("'")
    if not core:
        return True
    words = _english_words()
    return core in words or core.removesuffix("'s") in words or core.replace("n't", "") in words


def ocr_ensemble(crop: Image.Image, language_correction=True, widths=ENSEMBLE_WIDTHS):
    """同一張對話框用不同縮放各跑一次 Vision，逐字投票。

    Vision 對這種像素字很敏感，尺寸差一點就會把 a 認成 o；
    但每次錯的位置不同，所以多數決可以把錯誤投掉。
    回傳 (清理後文字, 各次結果列表)。
    """
    from collections import Counter

    texts = [normalize([t for t, _ in vision_ocr(prep_best(crop, target_width=w), language_correction)])
             for w in widths]
    texts = [t for t in texts if t]
    if not texts:
        return "", texts

    # 字數最常見的那一組才參加逐字投票（字數不同代表斷字方式不同，無法逐字對齊）
    token_lists = [t.split(" ") for t in texts]
    common_len = Counter(len(t) for t in token_lists).most_common(1)[0][0]
    group = [t for t in token_lists if len(t) == common_len]

    out = []
    for i in range(common_len):
        votes = Counter(t[i] for t in group)
        # 真的英文字多加一票：只在 Vision 自己意見分歧時才有作用，
        # 每次都讀成同一個口音拼寫（如 'ere）的字不受影響
        best = max(votes.items(), key=lambda kv: (kv[1] + (1 if len(votes) > 1 and _is_word(kv[0]) else 0),
                                                   _is_word(kv[0])))
        out.append(best[0])
    return " ".join(out), texts


# ---------- 文字清理 ----------

_SPEAKER = re.compile(r"^\s*[*＊]\s*:?\s*")         # 「*:」說話者標記，或 OCR 多讀到的開頭「*」
_PAGE_MARK = re.compile(r"\s*[▼▽◆◇♦]\s*$")        # 翻頁符號


def normalize(lines):
    """合併斷行、去掉說話者標記與翻頁符號、整理空白與引號。"""
    text = " ".join(l.strip() for l in lines if l.strip())
    text = _SPEAKER.sub("", text)
    text = _PAGE_MARK.sub("", text)
    text = text.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    text = re.sub(r"(\w)- (\w)", r"\1\2", text)  # 行尾連字號斷字
    text = re.sub(r"\s+", " ", text).strip()
    return text
