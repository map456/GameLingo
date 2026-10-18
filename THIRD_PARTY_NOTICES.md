# Third-Party Notices / 第三方元件與授權

GameLingo's own source code is released under the MIT License (see `LICENSE`).
GameLingo 自己的程式碼採用 MIT 授權（見 `LICENSE`）。

The following models and data are **not included in this repository**. `build.sh` downloads them
from their original sources on your machine, and each one stays under its own license.
以下模型與資料**不包含在本 repo**，由 `build.sh` 在你的電腦上從原始來源下載，各自依原授權使用。

| Component 元件 | Used for 用途 | License 授權 | Source 來源 |
| --- | --- | --- | --- |
| Seed-X-PPO-7B (ByteDance) | Alternative translation model 可切換的翻譯模型 | OpenMDW | https://huggingface.co/ByteDance-Seed/Seed-X-PPO-7B |
| Qwen3.5-9B (Alibaba Qwen, MLX 8-bit by mlx-community) | Default translation and context explanation 預設的翻譯與語境解說 | Apache-2.0 | https://huggingface.co/mlx-community/Qwen3.5-9B-MLX-8bit |
| Qwen3-8B (Alibaba Qwen, MLX 4-bit by mlx-community) | 💡 Context explanation 語境解說 | Apache-2.0 | https://huggingface.co/mlx-community/Qwen3-8B-4bit |
| ECDICT (`ecdict.csv`, `wordroot.txt`) | English–Chinese dictionary, word roots 英漢字典、字根表 | MIT | https://github.com/skywind3000/ECDICT |
| MorphoLex-en | Morphological segmentation 字首／字根／字尾拆解 | **CC BY-NC-SA 4.0 (non-commercial only 僅限非商業)** | https://github.com/hugomailhot/MorphoLex-en |

> ⚠️ MorphoLex-en is licensed for **non-commercial use only**, and works derived from it must use the
> same license. The word-root database built from it (`data/morph.db`) is therefore not distributed here.
> If you use GameLingo commercially, remove the MorphoLex step from `build.sh`.
>
> ⚠️ MorphoLex-en **僅限非商業使用**，衍生資料也必須採用相同授權，所以由它建立的字根資料庫
> （`data/morph.db`）不在本 repo 散布。若要商業使用，請移除 `build.sh` 中的 MorphoLex 步驟。

Python and Swift libraries (installed by `uv` / SwiftPM):
Python 與 Swift 套件（由 `uv`／SwiftPM 安裝）：

| Library 套件 | License 授權 |
| --- | --- |
| mlx, mlx-lm (Apple) | MIT |
| opencc-python-reimplemented | Apache-2.0 |
| openpyxl | MIT |
| ocrmac (stage 0 only 僅階段 0) | MIT |
| Pillow (stage 0 only 僅階段 0) | MIT-CMU (HPND) |

System frameworks: Apple Vision (OCR), AVFoundation (speech), SQLite.
系統框架：Apple Vision（文字辨識）、AVFoundation（發音）、SQLite。

Content created for this project:
本專案自行製作的內容：

- `server/affix_zh.json`: Chinese meanings of 188 prefixes and suffixes, written by hand (MIT).
  188 條字首字尾的中文意思，人工整理（MIT）。
- Chinese meanings of word roots are machine-translated with Seed-X at build time (`data/wordroot_zh.json`, not distributed).
  字根的中文意思在建立資料庫時由 Seed-X 機器翻譯（`data/wordroot_zh.json`，不散布）。
- App icon `GameLingo/Resources/AppIcon*`: provided by the project author.
  App 圖示 `GameLingo/Resources/AppIcon*`：由專案作者提供。

GameLingo does not include, modify or distribute any game ROM, BIOS or game assets.
"Dragon Quest" is a trademark of Square Enix and is mentioned only to describe compatibility.
GameLingo 不包含、不修改、也不散布任何遊戲 ROM、BIOS 或遊戲素材。
「Dragon Quest」是 Square Enix 的商標，在這裡提到只是為了說明相容性。
