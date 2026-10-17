"""GameLingo 本機翻譯伺服器：Seed-X-PPO-7B（MLX）＋專名保護＋OpenCC 台灣正體。

GameLingo App 會自動啟動它；也可以手動跑來測試：
    cd server
    uv run python gamelingo_server.py --port 8765

API：
    GET  /health      → {"ready": true/false, "error": ...}
    POST /translate   body {"text": "...", "names": ["Xi"], "mode": "translate" | "explain"}
                      回應是一行一個 JSON（NDJSON），邊產生邊送：
                        {"zh": "目前為止的整段譯文"}
                        ...
                        {"done": true, "zh": "最終譯文", "seconds": 0.8, "placeholder_lost": []}
                      新的請求進來時，舊的會自動停止（只處理最新一句）。

Seed-X 串接要點（實測結果見 CLAUDE.md）：
- 沒有 chat template，提示句結尾一定要加 <zh>
- 模型輸出開頭會有 <s>，要濾掉
- 輸出不分繁簡 → 每次更新都對「整段」重跑 OpenCC s2twp（避免詞被切斷轉錯）
- 專名佔位符用 X1、X2（⟦1⟧、NAME1 等寫法實測會被模型改掉）
"""

import argparse
import json
import queue
import re
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from opencc import OpenCC

PROMPT = "Translate the following English sentence into Chinese:\n{text} <zh>"
PROMPT_EXPLAIN = "Translate the following English sentence into Chinese and explain it in detail:\n{text} <zh>"

s2twp = OpenCC("s2twp")


# ---------- 專名保護（ProperNounGuard） ----------

def _dict_words():
    # 只收小寫開頭的字：字典裡大寫開頭的多半是人名地名（裡面甚至有 Ragnar）
    try:
        with open("/usr/share/dict/words") as f:
            return {w.strip() for w in f if w[:1].islower()}
    except OSError:
        return set()


DICT = _dict_words()

# 大寫開頭但不是名字的感嘆詞、口音字
NOT_NAMES = {"Oi", "Och", "Bah", "Hmph", "Hmm", "Mmm", "Eh", "Ah", "Oh", "Aye", "Nae", "Ye", "Yer",
             "Wot", "Gah", "Ooh", "Ho", "Huh", "Hah", "Ha", "Erm", "Um", "Uh", "Ow", "Ugh", "Whoa", "Wha",
             # DQ4 蘇格蘭／方言口音字（句首大寫時會被誤當成名字）
             "Hoo", "Oor", "Ach", "Dinnae", "Cannae", "Wouldnae", "Didnae", "Isnae", "Wasnae", "Ken", "Yon", "Lass"}


def find_proper_nouns(text, known_names):
    """known_names（例如自己取的主角名 Xi）一律保護；
    其他大寫開頭、小寫形式又不是一般英文字的，也當成專有名詞（Alena、Burland…）。"""
    names = [n for n in known_names if n and re.search(rf"\b{re.escape(n)}\b", text)]
    # [A-Z][a-z]+ 後面可以再接大寫開頭的段落：McRyan、MacDonald 這種名字才會整個抓到
    for m in re.finditer(r"\b[A-Z][a-z]+(?:[A-Z][a-z]+)*(?:'s)?\b", text):
        w = m.group(0).removesuffix("'s")
        if w in NOT_NAMES or w in names:
            continue
        if w.lower() not in DICT:
            names.append(w)
    return names


def placeholder(i):
    return f"X{i}"


def protect(text, known_names):
    names = find_proper_nouns(text, known_names)
    for i, n in enumerate(names, 1):
        text = re.sub(rf"\b{re.escape(n)}\b", placeholder(i), text)
    return text, names


def restore(text, names):
    missing = []
    for i, n in reversed(list(enumerate(names, 1))):  # 倒著換，避免 X1 吃掉 X10
        ph = placeholder(i)
        if ph in text:
            text = text.replace(ph, n)
        else:
            missing.append(n)
    return text, missing


def clean(text):
    return re.sub(r"</?s>|<unk>", "", text).strip()


# 一般翻譯時，模型偶爾會自己接著寫「[COT] 好的，我現在需要…」解說或「（注：…）」，
# 單句譯文不會有空行，所以遇到 [COT] 或空行就截斷
_RAMBLE = re.compile(r"\[COT\]|\n\s*\n|\n\s*[（(]注")


# 解說開頭常是模型自言自語（「好的，我現在需要處理使用者的這個翻譯請求…」），刪掉這種段落
_META = re.compile(r"使用者|用戶|翻譯請求|我現在需要|我需要把|我要仔細|首先，我")


def trim_meta(text):
    paras = [p for p in re.split(r"\n\s*\n", text)]
    while paras and _META.search(paras[0]) and len(paras) > 1:
        paras.pop(0)
    # 結尾的「總結一下…翻譯過程中需要注意…」也是寫給自己的
    while len(paras) > 1 and re.search(r"總結一下|翻譯過程中|確保譯文|通讀一遍", paras[-1]):
        paras.pop()
    return "\n\n".join(p.strip() for p in paras).strip()


def cut_ramble(text):
    m = _RAMBLE.search(text)
    return text[:m.start()].rstrip() if m else text


# ---------- 查字典（ECDICT） ----------

DICT_PATH = Path(__file__).resolve().parent.parent / "data" / "ecdict.db"
POS_NAMES = {"n": "名詞", "v": "動詞", "j": "形容詞", "a": "形容詞", "r": "副詞", "d": "限定詞", "i": "介系詞",
             "c": "連接詞", "p": "代名詞", "u": "感嘆詞", "m": "數詞", "t": "冠詞", "x": "其他"}


def _dict_row(conn, word):
    cur = conn.execute("SELECT word, phonetic, translation, pos, exchange, tag FROM stardict "
                       "WHERE word = ? COLLATE NOCASE LIMIT 1", (word,))
    r = cur.fetchone()
    if not r:
        return None
    word, phonetic, translation, pos, exchange, tag = r
    lines = [s2twp.convert(x.strip()) for x in (translation or "").replace("\\n", "\n").split("\n") if x.strip()]
    ex = dict(part.split(":", 1) for part in (exchange or "").split("/") if ":" in part)
    return {"word": word, "phonetic": phonetic or "", "translation": lines, "exchange": ex,
            "tags": (tag or "").split()}


def lookup(raw):
    """點到的字 → 字典資料。會處理大小寫、所有格、口音的 -in'（→ -ing），並找出原形（lemma）。"""
    if not DICT_PATH.exists():
        return {"found": False, "error": "還沒有字典檔，請執行 ./build.sh"}
    w = re.sub(r"^[^A-Za-z']+|[^A-Za-z']+$", "", raw)   # 去掉前後標點
    if not w.lower().endswith("in'"):                      # 保留 disappearin' 尾巴的撇號
        w = w.strip("'")
    cands = []
    for c in (w, w.lower()):
        if c and c not in cands:
            cands.append(c)
    low = w.lower()
    if low.endswith("in'"):
        cands.append(low[:-1] + "g")          # disappearin' → disappearing
    if low.endswith("'s"):
        cands.append(low[:-2])                # Ragnar's → ragnar
    if low.endswith("s'"):
        cands.append(low[:-1])
    conn = sqlite3.connect(f"file:{DICT_PATH}?mode=ro", uri=True)
    try:
        row = None
        for c in cands:
            row = _dict_row(conn, c)
            if row:
                break
        if not row:
            return {"found": False, "word": w}
        lemma = None
        base = row["exchange"].get("0")
        if base and base.lower() != row["word"].lower():
            lemma = _dict_row(conn, base)
        return {"found": True, "query": w, **row, "lemma": lemma}
    finally:
        conn.close()


# ---------- 字根拆解（MorphoLex＋ECDICT wordroot） ----------

MORPH_PATH = Path(__file__).resolve().parent.parent / "data" / "morph.db"
_SEGM = re.compile(r"<([^<>{}()]+)<|\(([^()]+)\)|>([^<>{}()]+)>")
_AFFIX_INDEX = None  # (類型, 形式) → [(key, 中文, 例字)]


def _affix_index(conn):
    """wordroot 的 key 像「-ance, -ence, -ency, -ancy」「in-1」，展開成每個變體方便查。"""
    global _AFFIX_INDEX
    if _AFFIX_INDEX is None:
        idx = {}
        for key, cls, zh, ex in conn.execute("SELECT key, class, meaning_zh, examples FROM affix ORDER BY key"):
            for v in key.split(","):
                v = re.sub(r"\d+$", "", v.strip())
                if v.endswith("-"):
                    kind, form = "prefix", v[:-1]
                elif v.startswith("-"):
                    kind, form = "suffix", v[1:]
                else:
                    kind, form = "root", v
                idx.setdefault((kind, form.lower()), []).append((key, zh, json.loads(ex or "[]")))
        _AFFIX_INDEX = idx
    return _AFFIX_INDEX


def _short_definition(dict_conn, word):
    """字根本身是英文字（例如 appear）時，用 ECDICT 第一個意思當說明"""
    if dict_conn is None:
        return ""
    row = _dict_row(dict_conn, word)
    if not row or not row["translation"]:
        return ""
    first = re.sub(r"^[a-z]+\.\s*", "", row["translation"][0])
    if "姓" in first or "人名" in first:   # MorphoLex 偶爾把字切出人名（kidd），不顯示
        return ""
    return "、".join(re.split(r"[,，;；]\s*", first)[:2])


def morph(raw):
    """單字 → 字首／字根／字尾拆解，每個部分附中文意思與同家族例字。"""
    if not MORPH_PATH.exists():
        return {"found": False, "error": "還沒有字根資料庫，請執行 ./build.sh"}
    w = re.sub(r"^[^A-Za-z']+|[^A-Za-z']+$", "", raw).strip("'").lower()
    cands = [w]
    if w.endswith("in"):
        cands.append(w + "g")                 # disappearin' → disappearing
    if w.endswith("'s"):
        cands.append(w[:-2])
    conn = sqlite3.connect(f"file:{MORPH_PATH}?mode=ro", uri=True)
    dconn = sqlite3.connect(f"file:{DICT_PATH}?mode=ro", uri=True) if DICT_PATH.exists() else None
    try:
        # 查不到變化形時，用 ECDICT 找原形再查（flitting → flit）
        if dconn is not None:
            for c in list(cands):
                row = _dict_row(dconn, c)
                base = row and row["exchange"].get("0")
                if base and base.lower() not in cands:
                    cands.append(base.lower())
        found = None
        for c in cands:
            r = conn.execute("SELECT word, segm FROM morph WHERE word = ?", (c,)).fetchone()
            if r:
                found = r
                break
        if not found:
            return {"found": False, "word": w}
        word, segm = found
        idx = _affix_index(conn)
        parts = []
        for m in _SEGM.finditer(segm):
            pre, root, suf = m.groups()
            kind, text = ("prefix", pre) if pre else ("root", root) if root else ("suffix", suf)
            entries = idx.get((kind, text.lower()), [])
            meanings = []
            for _, zh, _ex in entries:
                if zh and zh not in meanings:
                    meanings.append(zh)
            examples = []
            for _, _zh, ex in entries:
                examples += [e for e in ex if e.lower() != word.lower() and e not in examples]
            if kind == "root":
                if not meanings:
                    d = _short_definition(dconn, text)
                    if d:
                        meanings.append(d)
                if len(examples) < 4:   # 同字根的其他字（MorphoLex 裡含這個字根的字，短的優先）
                    # 排除只是變化形的（cared、caring 的拆解就是 {(care)}），只列有加字首字尾的衍生字
                    for (e,) in conn.execute("SELECT word FROM morph WHERE segm LIKE ? AND segm <> ? AND word <> ? "
                                             "ORDER BY length(word) LIMIT 8",
                                             (f"%({text})%", f"{{({text})}}", word)):
                        if e not in examples:
                            examples.append(e)
            parts.append({"type": kind, "text": text, "meaning": "／".join(meanings[:2]),
                          "examples": examples[:6]})
        return {"found": True, "word": word, "parts": parts}
    finally:
        conn.close()
        if dconn is not None:
            dconn.close()


# ---------- 模型工作執行緒 ----------
# MLX 的運算要在同一個執行緒做，所以所有生成都交給這一條執行緒，HTTP 只負責排隊與回傳。

class Job:
    def __init__(self, job_id, text, names, mode):
        self.id = job_id
        self.text = text
        self.names = names
        self.mode = mode
        self.out = queue.Queue()
        self.cancelled = False


class Engine:
    """模型工作執行緒。可以卸載模型（OpenEmu 關掉時釋放約 8 GB 記憶體），需要時再載入。
    字典／字根查詢不需要模型，卸載後照常可用。"""

    def __init__(self, model_path, preload=True):
        self.model_path = model_path
        self.jobs = queue.Queue()
        self.ready = False      # 模型已載入
        self.loading = False
        self.error = None
        self.latest = {}        # 各模式（translate／explain）最新的 job id；舊的同模式工作會被取消
        self.next_id = 0
        self.lock = threading.Lock()
        self.model = self.tok = None
        threading.Thread(target=self._run, daemon=True).start()
        if preload:
            self.request_load()

    def request_load(self):
        if not self.ready:
            self.loading = True
            self.jobs.put("load")

    def request_unload(self):
        self.jobs.put("unload")

    def submit(self, text, names, mode):
        with self.lock:
            self.next_id += 1
            job = Job(self.next_id, text, names, mode)
            self.latest[mode] = job.id
        self.request_load()  # 模型被卸載了就先載回來
        self.jobs.put(job)
        return job

    def _stale(self, job):
        return job.cancelled or job.id != self.latest.get(job.mode)

    def _load(self):
        if self.ready:
            return
        try:
            from mlx_lm import load, stream_generate
            from mlx_lm.sample_utils import make_sampler

            t0 = time.perf_counter()
            self.loading = True
            self.model, self.tok = load(self.model_path)
            self.stream_generate = stream_generate
            self.make_sampler = make_sampler
            self.ready = True
            self._generate(PROMPT.format(text="Hello."), None, 0.0, 8)  # 預熱
            self.error = None
            log(f"模型就緒（{time.perf_counter() - t0:.1f} 秒）：{self.model_path}")
        except Exception as e:  # noqa: BLE001
            self.error = f"{type(e).__name__}: {e}"
            log("模型載入失敗：" + self.error)
        finally:
            self.loading = False

    def _unload(self):
        if not self.ready:
            return
        import gc

        import mlx.core as mx

        self.ready = False
        self.model = self.tok = None
        gc.collect()
        try:
            mx.clear_cache()
        except AttributeError:
            mx.metal.clear_cache()
        log("模型已卸載，釋放記憶體（字典查詢仍可用）")

    def _run(self):
        while True:
            item = self.jobs.get()
            if item == "load":
                self._load()
                continue
            if item == "unload":
                self._unload()
                continue
            job = item
            if self._stale(job):
                job.out.put(None)
                continue
            if not self.ready:
                job.out.put({"done": True, "error": self.error or "模型沒有載入"})
                job.out.put(None)
                continue
            try:
                self._handle(job)
            except Exception as e:  # noqa: BLE001
                job.out.put({"done": True, "error": f"{type(e).__name__}: {e}"})
            job.out.put(None)

    def _generate(self, prompt, job, temp, max_tokens, on_text=None, stop_ramble=False):
        raw = ""
        for r in self.stream_generate(self.model, self.tok, prompt, max_tokens=max_tokens,
                                      sampler=self.make_sampler(temp=temp)):
            raw += r.text
            if job is not None and self._stale(job):
                return None
            if stop_ramble and _RAMBLE.search(raw):
                return cut_ramble(raw)
            if on_text:
                on_text(raw)
        return cut_ramble(raw) if stop_ramble else raw

    def _handle(self, job):
        if job.mode == "explain":
            self._explain(job)
            return
        t0 = time.perf_counter()
        guarded, names = protect(job.text, job.names)

        def emit(raw):
            zh, _ = restore(s2twp.convert(clean(raw)), names)
            job.out.put({"zh": zh})

        raw = self._generate(PROMPT.format(text=guarded), job, 0.0, 256, emit, stop_ramble=True)
        if raw is None:
            job.out.put({"done": True, "cancelled": True})
            return
        zh, missing = restore(s2twp.convert(clean(raw)), names)
        if missing:
            # 佔位符被模型弄丟 → 改成不保護直接翻（專名可能變音譯，但句子完整）
            raw = self._generate(PROMPT.format(text=job.text), job, 0.0, 256, stop_ramble=True)
            if raw is None:
                job.out.put({"done": True, "cancelled": True})
                return
            zh = s2twp.convert(clean(raw))
        job.out.put({"done": True, "zh": zh, "seconds": round(time.perf_counter() - t0, 2),
                     "placeholder_lost": missing, "names": names})

    def _explain(self, job):
        """語境解說：Seed-X 官方「翻譯並詳細解說」寫法。
        實測 greedy 只會翻譯不解說，要用取樣（溫度 0.7）才會在譯文後面接「[COT] …」解說，
        而且不一定每次都有 → 沒有解說就重試，最多 3 次。"""
        t0 = time.perf_counter()
        guarded, names = protect(job.text, job.names)

        def split(raw):
            text = s2twp.convert(clean(raw))
            zh, _, exp = text.partition("[COT]")
            zh, _ = restore(zh.strip(), names)
            exp, _ = restore(trim_meta(exp.strip()), names)
            return zh, exp

        for attempt in range(3):
            def emit(raw):
                zh, exp = split(raw)
                job.out.put({"zh": zh, "explanation": exp, "attempt": attempt + 1})

            raw = self._generate(PROMPT_EXPLAIN.format(text=guarded), job, 0.7, 1024, emit)
            if raw is None:
                job.out.put({"done": True, "cancelled": True})
                return
            zh, exp = split(raw)
            if exp:
                break
        job.out.put({"done": True, "zh": zh, "explanation": exp, "seconds": round(time.perf_counter() - t0, 1)})


# ---------- HTTP ----------

ENGINE: Engine = None


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # 安靜一點
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/morph"):
            from urllib.parse import parse_qs, urlparse
            word = parse_qs(urlparse(self.path).query).get("word", [""])[0]
            self._json(200, morph(word))
            return
        if self.path.startswith("/lookup"):
            from urllib.parse import parse_qs, urlparse
            word = parse_qs(urlparse(self.path).query).get("word", [""])[0]
            self._json(200, lookup(word))
            return
        if self.path == "/health":
            self._json(200, {"ready": ENGINE.ready, "loading": ENGINE.loading, "error": ENGINE.error,
                             "model": ENGINE.model_path})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/load":
            ENGINE.request_load()
            self._json(200, {"ok": True})
            return
        if self.path == "/unload":
            ENGINE.request_unload()
            self._json(200, {"ok": True})
            return
        if self.path != "/translate":
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            text = str(req.get("text", "")).strip()
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad json"})
            return
        if not text:
            self._json(400, {"error": "empty text"})
            return
        if ENGINE.error and not ENGINE.ready and not ENGINE.loading:
            self._json(503, {"error": ENGINE.error})
            return

        job = ENGINE.submit(text, [str(x) for x in req.get("names", [])], req.get("mode", "translate"))
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                item = job.out.get()
                if item is None:
                    break
                data = (json.dumps(item, ensure_ascii=False) + "\n").encode()
                self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")
                self.wfile.flush()
                if item.get("done"):
                    log(f"{text!r} → {item.get('zh', item.get('error', '（取消）'))!r} {item.get('seconds', '')}")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            job.cancelled = True  # App 取消了這句（例如按了新的翻譯）


def main():
    global ENGINE
    default_model = Path(__file__).resolve().parent.parent / "models" / "seedx-mlx-8bit"
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--model", default=str(default_model))
    ap.add_argument("--lazy", action="store_true", help="啟動時不載入模型（等 /load 或第一次翻譯）")
    args = ap.parse_args()

    ENGINE = Engine(args.model, preload=not args.lazy)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    log(f"GameLingo 伺服器啟動：http://127.0.0.1:{args.port}（模型載入中…）")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
