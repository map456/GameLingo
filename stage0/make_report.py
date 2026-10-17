"""把 out/ 裡的測試結果整理成 out/report.html，讓你逐句判斷譯文好不好。

用法：
    uv run python make_report.py
    open out/report.html
"""

import html
import json
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "out"

BACKENDS = [
    ("mlx-bf16", "MLX 原版 BF16（品質基準，greedy）"),
    ("mlx-bf16-beam4", "MLX BF16＋beam 4（官方建議解碼）"),
    ("mlx-8bit", "MLX 8-bit（自己轉的）"),
    ("ollama-q8", "Ollama 社群 GGUF Q8_0"),
]


def esc(s):
    return html.escape(str(s if s is not None else ""))


def img_data(path):
    """圖片直接嵌進 HTML，這樣報表單獨傳給別人或搬位置也看得到。"""
    import base64
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()


def load(name):
    p = OUT / f"translate_{name}.json"
    return json.loads(p.read_text()) if p.exists() else None


def ocr_section():
    p = OUT / "ocr_results.json"
    if not p.exists():
        return "<p>還沒跑 OCR 測試。</p>"
    rows = json.loads(p.read_text())
    combos = defaultdict(list)
    for r in rows:
        combos[(r["preprocess"], r["language_correction"])].append(r)
    names = {"raw": "原圖", "gray": "灰階", "binary": "二值化", "binary_half": "二值化＋縮半",
             "best": "二值化＋固定寬度＋留白", "ensemble": "多尺寸投票（採用）"}
    trs = []
    for (pp, lc), rs in sorted(combos.items(), key=lambda kv: (-sum(r["similarity"] == 1 for r in kv[1]),
                                                               sum(r["ms"] for r in kv[1]))):
        exact = sum(r["similarity"] == 1 for r in rs)
        ms = sum(r["ms"] for r in rs) / len(rs)
        wrong = sorted({r["text"] for r in rs if r["similarity"] != 1})
        cls = "good" if exact == len(rs) else ("" if exact else "bad")
        trs.append(f"<tr class='{cls}'><td>{names.get(pp, pp)}</td><td>{'開' if lc else '關'}</td>"
                   f"<td class='num'>{exact}/{len(rs)}</td><td class='num'>{ms:.0f} ms</td>"
                   f"<td class='small'>{'<br>'.join(esc(w) for w in wrong)}</td></tr>")
    imgs = sorted({r["image"] for r in rows})
    crops = "".join(f"<figure><img src='{img_data(OUT / 'crops' / (Path(i).stem + '_best.png'))}' alt='{esc(i)} 對話框'>"
                    f"<figcaption>{esc(i)}</figcaption></figure>" for i in imgs)
    return f"""
<p>每張截圖都自動找到對話框（白色外框）。下面是裁切＋前處理後實際送進 Vision 的圖：</p>
<div class="crops">{crops}</div>
<table><thead><tr><th>前處理</th><th>語言校正</th><th>完全正確</th><th>平均耗時</th><th>錯誤內容</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table>"""


def summary_section(data):
    trs = []
    for key, label in BACKENDS:
        d = data.get(key)
        if not d:
            continue
        s = d["summary"]
        mem = f"{s['peak_memory_gb']:.1f} GB" if s.get("peak_memory_gb") else "—"
        bad = "bad" if s["under_3s"] < s["count"] else ""
        trs.append(f"<tr class='{bad}'><td>{label}</td><td class='num'>{s['median_total_s']:.2f} s</td>"
                   f"<td class='num'>{s['max_total_s']:.2f} s</td><td class='num'>{s['under_3s']}/{s['count']}</td>"
                   f"<td class='num'>{mem}</td></tr>")
    return f"""<table><thead><tr><th>後端</th><th>中位數</th><th>最慢</th><th>3 秒內</th><th>模型記憶體</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table>"""


def sentence_section(data):
    base = data["mlx-bf16"]["rows"]
    out = []
    for i, r in enumerate(base):
        cells = []
        for key, label in BACKENDS:
            d = data.get(key)
            if not d:
                continue
            rr = next(x for x in d["rows"] if x["id"] == r["id"])
            t = rr["translation"]
            if len(t) > 160:
                t = t[:160] + "…（後面省略）"
            g = ""
            if rr.get("guarded_translation"):
                warn = f" <span class='warn'>佔位符遺失 {esc(rr['guarded_missing'])}</span>" if rr["guarded_missing"] else ""
                g = f"<div class='guard'>專名保護版：{esc(rr['guarded_translation'])}{warn}</div>"
            cells.append(f"<div class='tr'><div class='label'>{label}・{rr['metrics']['total_s']:.2f}s</div>"
                         f"<div class='zh'>{esc(t)}</div>{g}</div>")
        judge = "".join(f"<label><input type='radio' name='j{i}' value='{v}'> {v}</label>"
                        for v in ("好", "可以", "看不懂", "錯誤"))
        out.append(f"""
<section class="card" data-id="{esc(r['id'])}">
  <div class="src"><span class="tag">{esc(r['source'])}</span> {esc(r['text'])}</div>
  {''.join(cells)}
  <div class="judge">你的判斷（以 BF16 為準）：{judge}
    <input class="note" type="text" placeholder="備註，例如：哪個字翻錯">
  </div>
</section>""")
    return "".join(out)


def explain_section(d):
    if not d or not d.get("explains"):
        return ""
    parts = []
    for e in d["explains"]:
        body = e["explanation"]
        has = "[COT]" in body
        flag = "" if has else "<span class='warn'>這次沒有產生解說</span>"
        parts.append(f"<details {'open' if has else ''}><summary>{esc(e['text'])}　"
                     f"<span class='small'>{e['metrics']['total_s']:.1f}s・{e['metrics']['tokens']} tokens</span> {flag}"
                     f"</summary><pre>{esc(body)}</pre></details>")
    return "".join(parts)


def main():
    data = {k: load(k) for k, _ in BACKENDS}
    data = {k: v for k, v in data.items() if v}
    if "mlx-bf16" not in data:
        raise SystemExit("找不到 out/translate_mlx-bf16.json，請先跑 translate_test.py --backend mlx-bf16")

    page = f"""<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>階段 0 驗證報表</title>
<style>
:root {{ --bg:#fafaf8; --fg:#1d1d1f; --muted:#6b6b70; --card:#fff; --line:#e3e3e0;
        --good:#e8f5e9; --bad:#fdecea; --accent:#2563eb; --warn:#b45309; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg:#161618; --fg:#ececef; --muted:#9a9aa2; --card:#1f1f22; --line:#333338;
          --good:#17301c; --bad:#3a1b1b; --accent:#7aa2ff; --warn:#f0b35a; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--fg);
       font:15px/1.6 -apple-system, "PingFang TC", "Helvetica Neue", sans-serif; }}
main {{ max-width:980px; margin:0 auto; padding:24px 16px 80px; }}
h1 {{ font-size:24px; margin:0 0 4px; }} h2 {{ font-size:19px; margin:36px 0 10px; border-bottom:1px solid var(--line); padding-bottom:6px; }}
.small {{ font-size:12px; color:var(--muted); }}
table {{ width:100%; border-collapse:collapse; background:var(--card); font-size:14px; }}
th, td {{ border:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; }}
td.num {{ text-align:right; white-space:nowrap; font-variant-numeric:tabular-nums; }}
tr.good td {{ background:var(--good); }} tr.bad td {{ background:var(--bad); }}
.crops {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:8px; margin:8px 0 12px; }}
.crops img {{ width:100%; border:1px solid var(--line); background:#fff; }}
figure {{ margin:0; }} figcaption {{ font-size:12px; color:var(--muted); }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px 14px; margin:12px 0; }}
.src {{ font-size:16px; font-weight:600; margin-bottom:8px; }}
.tag {{ font-size:11px; font-weight:500; color:var(--muted); border:1px solid var(--line); border-radius:4px; padding:1px 5px; }}
.tr {{ padding:4px 0; border-top:1px dashed var(--line); }}
.label {{ font-size:12px; color:var(--muted); }} .zh {{ font-size:16px; }}
.guard {{ font-size:13px; color:var(--muted); }}
.warn {{ color:var(--warn); font-weight:600; }}
.judge {{ margin-top:8px; font-size:14px; display:flex; flex-wrap:wrap; gap:10px; align-items:center; }}
.note {{ flex:1; min-width:180px; padding:4px 6px; border:1px solid var(--line); border-radius:4px; background:var(--bg); color:var(--fg); }}
pre {{ white-space:pre-wrap; background:var(--bg); padding:10px; border-radius:6px; font-size:13px; }}
details {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:8px 12px; margin:8px 0; }}
summary {{ cursor:pointer; font-weight:600; }}
.bar {{ position:sticky; bottom:0; background:var(--card); border-top:1px solid var(--line); padding:10px 16px; text-align:center; }}
button {{ font:inherit; padding:6px 16px; border-radius:6px; border:0; background:var(--accent); color:#fff; cursor:pointer; }}
</style></head><body><main>
<h1>階段 0 驗證報表</h1>
<p class="small">Dragon Quest IV（NDS）・Vision OCR＋Seed-X-PPO-7B。判斷完按最下面的按鈕，把結果貼回給 Claude。</p>

<h2>1. OCR（Apple Vision）</h2>
{ocr_section()}

<h2>2. 翻譯速度與記憶體</h2>
{summary_section(data)}
<p class="small">OCR 約 0.3 秒＋翻譯約 0.3～0.9 秒。Ollama 那一列的「最慢」是模型失控、一直重複同一段字。</p>

<h2>3. 逐句譯文（請判斷）</h2>
<p class="small">「截圖實際台詞」來自你的截圖；「CLAUDE.md 範例句」是 Seed-X 官方範例；其他是 Claude 自己編的 DQ 風格句子，用來測口音、古英文、專有名詞，不是遊戲原文。</p>
{sentence_section(data)}

<h2>4. 「翻譯並詳細解說」</h2>
<p class="small">用溫度 0.7 取樣（greedy 時模型只翻譯、不解說）。有解說時會出現在「[COT]」後面。</p>
{explain_section(data.get('mlx-bf16'))}

</main>
<div class="bar"><button id="export">複製我的判斷</button> <span id="msg" class="small"></span></div>
<script>
const KEY = 'gamelingo-stage0-judge';
function save() {{
  const out = {{}};
  document.querySelectorAll('.card').forEach(c => {{
    const v = c.querySelector('input[type=radio]:checked');
    const n = c.querySelector('.note').value;
    if (v || n) out[c.dataset.id] = {{ judge: v ? v.value : null, note: n }};
  }});
  try {{ localStorage.setItem(KEY, JSON.stringify(out)); }} catch (e) {{}}
  return out;
}}
try {{
  const saved = JSON.parse(localStorage.getItem(KEY) || '{{}}');
  document.querySelectorAll('.card').forEach(c => {{
    const s = saved[c.dataset.id]; if (!s) return;
    if (s.judge) c.querySelectorAll('input[type=radio]').forEach(r => r.checked = r.value === s.judge);
    c.querySelector('.note').value = s.note || '';
  }});
}} catch (e) {{}}
document.addEventListener('change', save);
document.addEventListener('input', save);
document.getElementById('export').onclick = async () => {{
  const text = JSON.stringify(save(), null, 1);
  try {{ await navigator.clipboard.writeText(text); document.getElementById('msg').textContent = '已複製，貼回給 Claude 即可'; }}
  catch (e) {{ prompt('請手動複製：', text); }}
}};
</script>
</body></html>"""
    (OUT / "report.html").write_text(page)
    print(f"已產生 {OUT / 'report.html'}")


if __name__ == "__main__":
    main()
