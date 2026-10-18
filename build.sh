#!/bin/bash
# GameLingo 一鍵編譯：準備翻譯伺服器環境 → 確認模型 → 編譯 Swift App → 打包成 build/GameLingo.app
#
# 用法（在專案資料夾）：
#     ./build.sh
# 完成後：
#     open build/GameLingo.app

set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/GameLingo.app"
MODEL="$ROOT/models/seedx-mlx-8bit"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

command -v uv >/dev/null || { echo "找不到 uv，請先執行：brew install uv"; exit 1; }
command -v swift >/dev/null || { echo "找不到 swift，請先安裝 Xcode"; exit 1; }

step "1/4 準備翻譯伺服器的 Python 環境"
(cd "$ROOT/server" && uv sync -q)

step "2/4 確認翻譯模型"
if [ -f "$MODEL/config.json" ]; then
    echo "已有模型：$MODEL"
else
    echo "第一次使用：下載 Seed-X-PPO-7B（約 15 GB）並轉成 MLX 8-bit，需要一段時間…"
    (cd "$ROOT/server" && uv run mlx_lm.convert --hf-path ByteDance-Seed/Seed-X-PPO-7B \
        --mlx-path "$MODEL" -q --q-bits 8)
fi

step "2a 確認語境解說模型（Qwen3-8B 4-bit）"
EXPLAINER="$ROOT/models/qwen3-8b-4bit"
if [ -f "$EXPLAINER/config.json" ]; then
    echo "已有解說模型：$EXPLAINER"
else
    echo "第一次使用：下載 Qwen3-8B（MLX 4-bit，約 4.3 GB），💡 語境解說用…"
    (cd "$ROOT/server" && uv run python -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/Qwen3-8B-4bit', local_dir='$EXPLAINER')")
fi

step "2b 確認字典（ECDICT）"
DICT="$ROOT/data/ecdict.db"
if [ -f "$DICT" ]; then
    echo "已有字典：$DICT"
elif [ "${SKIP_DICT:-}" = "1" ]; then
    echo "略過字典（SKIP_DICT=1）；點字查詢會顯示「還沒有字典檔」"
else
    echo "第一次使用：下載 ECDICT 英漢字典（約 66 MB）並建立索引…"
    mkdir -p "$ROOT/data/download"
    if [ ! -f "$ROOT/data/download/ecdict.csv" ]; then
        curl -fSL -o "$ROOT/data/download/ecdict.csv.part" \
            https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv
        mv "$ROOT/data/download/ecdict.csv.part" "$ROOT/data/download/ecdict.csv"
    fi
    (cd "$ROOT/server" && uv run python build_dict.py "$ROOT/data/download/ecdict.csv" "$DICT")
fi

step "2c 確認字根資料庫（MorphoLex＋ECDICT wordroot）"
MORPH="$ROOT/data/morph.db"
if [ -f "$MORPH" ]; then
    echo "已有字根資料庫：$MORPH"
elif [ "${SKIP_DICT:-}" = "1" ]; then
    echo "略過字根資料庫（SKIP_DICT=1）"
else
    echo "第一次使用：下載 MorphoLex（約 7 MB）與字根表，並用模型翻譯字根意思（約 2 分鐘）…"
    DL="$ROOT/data/download"
    mkdir -p "$DL/morpholex"
    [ -f "$DL/morpholex/MorphoLEX_en.xlsx" ] || curl -fSL -o "$DL/morpholex/MorphoLEX_en.xlsx" \
        https://raw.githubusercontent.com/hugomailhot/MorphoLex-en/master/MorphoLEX_en.xlsx
    [ -f "$DL/wordroot.txt" ] || curl -fSL -o "$DL/wordroot.txt" \
        https://raw.githubusercontent.com/skywind3000/ECDICT/master/wordroot.txt
    (cd "$ROOT/server" && uv run python build_morph.py "$DL/morpholex/MorphoLEX_en.xlsx" "$DL/wordroot.txt" "$MORPH")
fi

step "3/4 編譯 App"
(cd "$ROOT/GameLingo" && swift build -c release 2>&1 | grep -Ev '^\[[0-9]+/[0-9]+\]' || true)
BIN="$ROOT/GameLingo/.build/release/GameLingo"
[ -x "$BIN" ] || { echo "編譯失敗，請把上面的訊息貼給 Claude"; exit 1; }

step "4/4 打包成 GameLingo.app"
# 如果 App 或翻譯伺服器正在執行，先關掉（伺服器程式改過時才會載入新版）
pkill -x GameLingo 2>/dev/null && sleep 1 || true
pkill -f gamelingo_server.py 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GameLingo"
cp "$ROOT/GameLingo/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.gamelingo.GameLingo</string>
    <key>CFBundleName</key><string>GameLingo</string>
    <key>CFBundleDisplayName</key><string>GameLingo</string>
    <key>CFBundleExecutable</key><string>GameLingo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>GameLingoRepoRoot</key><string>$ROOT</string>
</dict>
</plist>
PLIST

# 用 Apple Development 憑證簽章：簽章固定，重新編譯後「螢幕錄製」權限不會失效
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1
    echo "已簽章：$IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1
    echo "注意：找不到開發者憑證，用臨時簽章；每次重新編譯後可能要重新授權螢幕錄製"
fi

printf "\n\033[1;32m完成！\033[0m 執行：open -g \"%s\"\n" "$APP"
