"""MLX 版 beam search（官方建議寬度 4）。mlx-lm 本身沒有 beam search，這裡自己實作。

做法：W 條候選共用一批 KV cache（batch 維度＝W），每一步把所有候選的下一個字
合在一起取分數最高的 W 個，再依新的排序重排 cache。
分數＝累積 log 機率 ÷ 長度（對應 vLLM BeamSearchParams 預設 length_penalty=1）。
"""

import mlx.core as mx
from mlx_lm.models.cache import make_prompt_cache

SPECIAL = {0, 1, 2}  # <unk> <s> </s>
EOS = 2


def beam_search(model, tokenizer, prompt: str, width=4, max_tokens=512):
    ids = tokenizer.encode(prompt)
    cache = make_prompt_cache(model)
    logits = model(mx.array([ids] * width), cache=cache)[:, -1, :]

    seqs = [[] for _ in range(width)]
    scores = mx.zeros((width,))
    finished = []  # (正規化分數, tokens)

    for step in range(max_tokens):
        logp = logits.astype(mx.float32) - mx.logsumexp(logits.astype(mx.float32), axis=-1, keepdims=True)
        cand = scores[:, None] + logp  # (W, V)
        if step == 0:
            cand = cand[:1]  # 一開始 W 條都一樣，只從第一條展開
        vocab = cand.shape[1]
        flat = cand.reshape(-1)
        k = 2 * width
        top = mx.argpartition(-flat, kth=k - 1)[:k]
        top = top[mx.argsort(-flat[top])]
        mx.eval(top, flat)
        top_l = top.tolist()
        flat_scores = flat[top].tolist()

        new_beams, new_tokens, new_scores = [], [], []
        for idx, sc in zip(top_l, flat_scores):
            b, tok = divmod(idx, vocab)
            seq = seqs[b] + [tok]
            if tok == EOS:
                finished.append((sc / len(seq), seq))
                continue
            new_beams.append(b)
            new_tokens.append(tok)
            new_scores.append(sc)
            seqs_next = seq
            if len(new_beams) == width:
                break
            del seqs_next

        # 已經有 W 條完成，而且剩下的最好分數也追不上 → 結束
        if len(finished) >= width:
            best_done = max(f[0] for f in finished)
            best_alive = max(new_scores) / (step + 1) if new_scores else float("-inf")
            if best_alive < best_done:
                break
        if not new_beams:
            break

        seqs = [seqs[b] + [t] for b, t in zip(new_beams, new_tokens)]
        scores = mx.array(new_scores)
        order = mx.array(new_beams)
        for c in cache:
            c.keys = c.keys[order]
            c.values = c.values[order]
        logits = model(mx.array(new_tokens)[:, None], cache=cache)[:, -1, :]

    if not finished:
        finished = [(float(s) / max(1, len(q)), q) for s, q in zip(scores.tolist(), seqs)]
    best = max(finished, key=lambda f: f[0])[1]
    return tokenizer.decode([t for t in best if t not in SPECIAL]).strip(), len(best)
