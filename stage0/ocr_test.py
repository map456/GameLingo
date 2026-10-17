"""OCR 測試：對 samples/ 每張截圖，找對話框 → 各種前處理 × 語言校正開關 → Vision OCR。

用法：
    uv run python ocr_test.py
輸出：
    out/crops/   每張圖裁出來的對話框與前處理結果（可以打開看）
    out/ocr_results.json
"""

import json
import time
from pathlib import Path

from PIL import Image

from common import PREPROCESSORS, find_dialog_box, normalize, ocr_ensemble, vision_ocr

HERE = Path(__file__).parent
SAMPLES = HERE / "samples"
OUT = HERE / "out"
CROPS = OUT / "crops"

# 已知正確答案（用來算正確率）；新增截圖時在 samples/answers.json 補上
ANSWERS_FILE = SAMPLES / "answers.json"


def similarity(a: str, b: str) -> float:
    """字元層級相似度（0～1），1 代表完全相同。"""
    from difflib import SequenceMatcher
    return SequenceMatcher(None, a, b).ratio()


def main():
    CROPS.mkdir(parents=True, exist_ok=True)
    answers = json.loads(ANSWERS_FILE.read_text()) if ANSWERS_FILE.exists() else {}
    results = []

    images = sorted(p for p in SAMPLES.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not images:
        print("samples/ 裡沒有圖片")
        return

    for path in images:
        img = Image.open(path)
        box = find_dialog_box(img)
        crop = img.crop(box)
        expected = answers.get(path.name)
        print(f"\n=== {path.name}  對話框 {box}")
        if expected:
            print(f"    正確答案：{expected}")

        methods = list(PREPROCESSORS.items()) + [("ensemble", None)]
        for pname, fn in methods:
            if fn:
                pimg = fn(crop)
                pimg.save(CROPS / f"{path.stem}_{pname}.png")
            for lc in (True, False):
                t0 = time.perf_counter()
                if fn:
                    lines = vision_ocr(pimg, language_correction=lc)
                    text = normalize([t for t, _ in lines])
                    conf = min((c for _, c in lines), default=0.0)
                else:
                    text, runs = ocr_ensemble(crop, language_correction=lc)
                    lines = [(r, 1.0) for r in runs]
                    conf = 1.0
                ms = (time.perf_counter() - t0) * 1000
                score = similarity(text, expected) if expected else None
                tag = "校正開" if lc else "校正關"
                mark = "" if score is None else ("  ✅" if score == 1 else f"  相似度 {score:.3f}")
                print(f"  [{pname:11s} {tag}] {ms:6.0f}ms  {text!r}{mark}")
                results.append({
                    "image": path.name,
                    "box": box,
                    "preprocess": pname,
                    "language_correction": lc,
                    "raw_lines": [t for t, _ in lines],
                    "text": text,
                    "min_confidence": conf,
                    "ms": round(ms),
                    "expected": expected,
                    "similarity": score,
                })

    (OUT / "ocr_results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2))

    # 各組合的平均表現
    if answers:
        print("\n=== 各組合平均（有正確答案的圖）")
        combos = {}
        for r in results:
            if r["similarity"] is None:
                continue
            k = (r["preprocess"], r["language_correction"])
            combos.setdefault(k, []).append(r)
        for (p, lc), rs in sorted(combos.items(), key=lambda kv: -sum(r["similarity"] for r in kv[1])):
            exact = sum(r["similarity"] == 1 for r in rs)
            avg = sum(r["similarity"] for r in rs) / len(rs)
            ms = sum(r["ms"] for r in rs) / len(rs)
            print(f"  {p:11s} {'校正開' if lc else '校正關'}  完全正確 {exact}/{len(rs)}  平均相似度 {avg:.3f}  平均 {ms:.0f}ms")

    print(f"\n結果已存到 {OUT / 'ocr_results.json'}")


if __name__ == "__main__":
    main()
