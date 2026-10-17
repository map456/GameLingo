"""把 ECDICT 的 ecdict.csv 轉成 SQLite（data/ecdict.db），給翻譯伺服器的 /lookup 用。

用法（build.sh 會自動執行）：
    uv run python build_dict.py <ecdict.csv> <輸出 ecdict.db>

ECDICT：https://github.com/skywind3000/ECDICT（MIT 授權）
欄位：word, phonetic, definition, translation, pos, collins, oxford, tag, bnc, frq, exchange, detail, audio
translation 裡的換行在 CSV 中寫成「\\n」兩個字元，查詢時再換回來。
"""

import csv
import sqlite3
import sys
from pathlib import Path


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    tmp = dst.with_suffix(".tmp")
    tmp.unlink(missing_ok=True)

    conn = sqlite3.connect(tmp)
    conn.execute("""CREATE TABLE stardict (
        word TEXT NOT NULL, phonetic TEXT, translation TEXT, pos TEXT,
        tag TEXT, exchange TEXT, frq INTEGER, bnc INTEGER)""")

    csv.field_size_limit(10_000_000)
    rows = []
    n = 0
    with src.open(encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            word = (r.get("word") or "").strip()
            if not word:
                continue
            rows.append((word, r.get("phonetic"), r.get("translation"), r.get("pos"), r.get("tag"),
                         r.get("exchange"), int(r.get("frq") or 0), int(r.get("bnc") or 0)))
            if len(rows) >= 50_000:
                conn.executemany("INSERT INTO stardict VALUES (?,?,?,?,?,?,?,?)", rows)
                n += len(rows)
                rows.clear()
    if rows:
        conn.executemany("INSERT INTO stardict VALUES (?,?,?,?,?,?,?,?)", rows)
        n += len(rows)
    conn.execute("CREATE INDEX idx_word_nocase ON stardict(word COLLATE NOCASE)")
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    tmp.replace(dst)
    print(f"字典完成：{n} 個詞條 → {dst}")


if __name__ == "__main__":
    main()
