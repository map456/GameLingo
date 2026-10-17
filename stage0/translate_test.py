"""翻譯測試：用不同後端跑 Seed-X-PPO-7B，量延遲，測專有名詞佔位符與「翻譯並解說」。

用法（在 stage0 資料夾裡）：
    uv run python translate_test.py --backend mlx-bf16
    uv run python translate_test.py --backend mlx-8bit
    uv run python translate_test.py --backend ollama-q8
輸出：out/translate_<backend>.json
"""

import argparse
import json
import re
import time
from pathlib import Path

import requests
from opencc import OpenCC

HERE = Path(__file__).parent
OUT = HERE / "out"
SENTENCES = json.loads((HERE / "test_sentences.json").read_text())

HF_MODEL = "ByteDance-Seed/Seed-X-PPO-7B"
MLX_8BIT_DIR = HERE.parent / "models" / "seedx-mlx-8bit"
OLLAMA_MODEL = "hf.co/mradermacher/Seed-X-PPO-7B-GGUF:Q8_0"

PROMPT = "Translate the following English sentence into Chinese:\n{text} <zh>"
PROMPT_EXPLAIN = "Translate the following English sentence into Chinese and explain it in detail:\n{text} <zh>"

s2twp = OpenCC("s2twp")


def clean(text):
    """模型會先吐出 <s>（官方範例用 skip_special_tokens 藏掉），這裡去掉特殊符號。"""
    return re.sub(r"</?s>|<unk>", "", text).strip()


# ---------- 專有名詞佔位符（ProperNounGuard 雛形） ----------

def _dict_words():
    # 只收小寫開頭的字：字典裡大寫開頭的多半是人名地名（裡面甚至有 Ragnar），不能拿來判斷一般字
    with open("/usr/share/dict/words") as f:
        return {w.strip() for w in f if w[:1].islower()}


DICT = _dict_words()

# 大寫開頭但不是名字的感嘆詞、口音字
NOT_NAMES = {"Oi", "Och", "Bah", "Hmph", "Hmm", "Eh", "Ah", "Oh", "Aye", "Nae", "Ye", "Yer", "Wot", "Gah", "Ooh", "Ho"}


def _known_names():
    """known_names.txt：一定要保留英文的名字（例如自己取的主角名 Xi，字典裡剛好有 xi 這個字）。"""
    p = HERE / "known_names.txt"
    if not p.exists():
        return []
    return [l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith("#")]


def find_proper_nouns(text):
    """大寫開頭、而且小寫形式不是一般英文字 → 當成專有名詞（Alena、Burland…）。
    像 Castle、Goddess 這種一般字照常翻譯。known_names.txt 裡的名字一律保護。"""
    names = [n for n in _known_names() if re.search(rf"\b{re.escape(n)}\b", text)]
    for m in re.finditer(r"\b[A-Z][a-z]+(?:'s)?\b", text):
        w = m.group(0).removesuffix("'s")
        if w in NOT_NAMES:
            continue
        if w.lower() not in DICT and w not in names:
            names.append(w)
    return names


# 實測：⟦1⟧ #1 {1} <1> 會讓模型加「號」或自己寫註解；NAME1 在呼喚語（"Xi!"、"now, Xi."）
# 會被翻成「姓名1號」；X1 在 7 種句型都原樣保留，最穩定
def placeholder(i):
    return f"X{i}"


def protect(text):
    names = find_proper_nouns(text)
    for i, n in enumerate(names, 1):
        text = re.sub(rf"\b{re.escape(n)}\b", placeholder(i), text)
    return text, names


def restore(text, names):
    missing = []
    # 倒過來換，避免 NAME1 先吃掉 NAME10 的前半段
    for i, n in reversed(list(enumerate(names, 1))):
        ph = placeholder(i)
        if ph in text:
            text = text.replace(ph, n)
        else:
            missing.append(n)
    return text, missing


# ---------- 後端 ----------

class MLXBackend:
    def __init__(self, path):
        import mlx.core as mx
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler

        self.mx = mx
        t0 = time.perf_counter()
        self.model, self.tok = load(str(path))
        self.load_s = time.perf_counter() - t0
        self.make_sampler = make_sampler
        self.beam = 0

    def generate(self, prompt, max_tokens=512, temp=0.0):
        from mlx_lm import stream_generate

        if self.beam and temp == 0.0:
            from beam import beam_search
            t0 = time.perf_counter()
            text, n = beam_search(self.model, self.tok, prompt, width=self.beam, max_tokens=max_tokens)
            total = time.perf_counter() - t0
            return text, {"first_token_s": None, "total_s": total, "tokens": n}

        sampler = self.make_sampler(temp=temp)  # temp=0 → greedy
        t0 = time.perf_counter()
        first = None
        text = ""
        n = 0
        for r in stream_generate(self.model, self.tok, prompt, max_tokens=max_tokens, sampler=sampler):
            if first is None:
                first = time.perf_counter() - t0
            text += r.text
            n = r.generation_tokens
        total = time.perf_counter() - t0
        return clean(text), {"first_token_s": first, "total_s": total, "tokens": n}

    def peak_memory_gb(self):
        return self.mx.get_peak_memory() / 1e9


class OllamaBackend:
    load_s = None

    def __init__(self, model):
        self.model = model
        t0 = time.perf_counter()
        self._call("Hello <zh>", 1)  # 預熱，把模型載進記憶體
        self.load_s = time.perf_counter() - t0

    def _call(self, prompt, max_tokens, temp=0.0):
        r = requests.post("http://localhost:11434/api/generate", json={
            "model": self.model,
            "prompt": prompt,
            "raw": True,                     # 不套 chat template（Seed-X 沒有 template）
            "stream": False,
            "keep_alive": "30m",
            "options": {"temperature": temp, "num_predict": max_tokens},
        }, timeout=600)
        r.raise_for_status()
        return r.json()

    def generate(self, prompt, max_tokens=512, temp=0.0):
        t0 = time.perf_counter()
        j = self._call(prompt, max_tokens, temp)
        total = time.perf_counter() - t0
        first = (j.get("load_duration", 0) + j.get("prompt_eval_duration", 0)) / 1e9
        return clean(j["response"]), {"first_token_s": first, "total_s": total, "tokens": j.get("eval_count", 0)}

    def peak_memory_gb(self):
        return None


def make_backend(name):
    if name == "mlx-bf16":
        return MLXBackend(HF_MODEL)
    if name == "mlx-8bit":
        if not MLX_8BIT_DIR.exists():
            raise SystemExit(f"找不到 {MLX_8BIT_DIR}，請先執行：uv run mlx_lm.convert --hf-path {HF_MODEL} "
                             f"--mlx-path {MLX_8BIT_DIR} -q --q-bits 8")
        return MLXBackend(MLX_8BIT_DIR)
    if name == "ollama-q8":
        return OllamaBackend(OLLAMA_MODEL)
    raise SystemExit(f"不認識的後端：{name}")


# ---------- 主程式 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, choices=["mlx-bf16", "mlx-8bit", "ollama-q8"])
    ap.add_argument("--beam", type=int, default=0, help="beam search 寬度（只有 MLX 後端；0 = greedy）")
    ap.add_argument("--explain", type=int, default=4, help="做「翻譯並解說」測試的句數（0 = 不做）")
    args = ap.parse_args()

    OUT.mkdir(exist_ok=True)
    print(f"載入 {args.backend} …")
    be = make_backend(args.backend)
    if args.beam:
        if not isinstance(be, MLXBackend):
            raise SystemExit("beam search 只支援 MLX 後端")
        be.beam = args.beam
    tag = args.backend + (f"-beam{args.beam}" if args.beam else "")
    print(f"載入完成 {be.load_s:.1f} 秒")

    # 預熱一次，避免第一句的時間包含編譯／快取
    be.generate(PROMPT.format(text="Hello."), max_tokens=8)

    rows = []
    for s in SENTENCES:
        # A. 直接翻（專名原樣送進去）
        raw, m1 = be.generate(PROMPT.format(text=s["text"]))
        plain = s2twp.convert(raw)

        # B. 佔位符保護專名
        guarded_src, names = protect(s["text"])
        guarded = None
        missing = []
        m2 = None
        if names:
            g_raw, m2 = be.generate(PROMPT.format(text=guarded_src))
            guarded, missing = restore(s2twp.convert(g_raw), names)

        print(f"\n[{s['id']}] {s['text']}")
        print(f"  直接翻譯 {m1['total_s']:.2f}s（首字 {m1['first_token_s'] or 0:.2f}s）：{plain}")
        if names:
            flag = "✅" if not missing else f"⚠️ 佔位符遺失：{missing}"
            print(f"  佔位符   {m2['total_s']:.2f}s：{guarded}  {flag}")

        rows.append({
            **s,
            "model_raw": raw,
            "translation": plain,
            "metrics": m1,
            "proper_nouns": names,
            "guarded_source": guarded_src if names else None,
            "guarded_translation": guarded,
            "guarded_missing": missing,
            "guarded_metrics": m2,
        })

    explains = []
    explain_ids = ["seedx-ex", "mock-archaic-1", "mock-accent-2", "mock-pun"]
    for s in [x for x in SENTENCES if x["id"] in explain_ids][: args.explain]:
        # 實測：greedy／beam 時模型只翻譯不解說；要用取樣（溫度 0.7）才會在譯文後面加「[COT]」解說
        raw, m = be.generate(PROMPT_EXPLAIN.format(text=s["text"]), max_tokens=1024, temp=0.7)
        explains.append({"id": s["id"], "text": s["text"], "explanation": s2twp.convert(raw), "metrics": m})
        print(f"\n[解說 {s['id']}] {m['total_s']:.1f}s，{m['tokens']} tokens\n{s2twp.convert(raw)}")

    times = sorted(r["metrics"]["total_s"] for r in rows)
    summary = {
        "backend": tag,
        "load_s": be.load_s,
        "peak_memory_gb": be.peak_memory_gb(),
        "median_total_s": times[len(times) // 2],
        "max_total_s": times[-1],
        "under_3s": sum(t < 3 for t in times),
        "count": len(times),
    }
    print("\n=== 摘要", json.dumps(summary, ensure_ascii=False, indent=2))
    (OUT / f"translate_{tag}.json").write_text(
        json.dumps({"summary": summary, "rows": rows, "explains": explains}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
