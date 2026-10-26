#!/bin/bash
# 把 SwiftPM 執行檔包成 SoundRouter.app 並簽章。
# Core Audio 的 process tap 一定要有 bundle 身分（Info.plist + 簽章）才拿得到
# TCC 授權；直接跑裸執行檔的話 tap 只會送回靜音。
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/SoundRouter.app"

# 建成 universal binary。開發時只跑自己的架構比較快，但這支腳本產出的是
# 要拿來用（或發布）的 .app，Intel 機器也該跑得起來。
#
# 不用 `swift build --arch arm64 --arch x86_64` 一次建完：多個 --arch 會讓 SwiftPM
# 改走 XCBuild 後端，而它（Swift 6.1）不認得 swiftLanguageMode(.v5)，直接建置失敗。
# 所以分架構各建一次，再用 lipo 合併。
ARCHS=(arm64 x86_64)
for arch in "${ARCHS[@]}"; do
    swift build -c "$CONFIG" --arch "$arch" --product SoundRouterApp
    swift build -c "$CONFIG" --arch "$arch" --product audiorouter
done

BIN_DIR="build/universal"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
ARCH_DIRS=()
for arch in "${ARCHS[@]}"; do
    ARCH_DIRS+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)")
done
for product in SoundRouterApp audiorouter; do
    lipo -create "${ARCH_DIRS[@]/%//$product}" -output "$BIN_DIR/$product"
done
# 資源 bundle 與架構無關，取任一份即可。
for bundle in "${ARCH_DIRS[0]}"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$BIN_DIR/"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/SoundRouterApp" "$APP/Contents/MacOS/SoundRouterApp"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM 把本地化字串放進執行檔旁邊的 .bundle。這個 .app 是手工組裝的，
# 不搬過去的話 Bundle.module 找不到資源，介面會退回顯示 key 本身。
# 放在 Contents/Resources 是因為 Bundle.module 會查 Bundle.main.resourceURL。
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 沒有 Developer ID 就用 ad-hoc 簽章。可以正常運作，但簽章雜湊會隨每次重建改變，
# 所以 TCC 授權在重建後可能需要重新勾選一次。
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# CLI 直接從 shell 執行時拿不到 process tap 的 TCC 授權（tap 會靜靜地回傳靜音），
# 所以另外包一份帶 bundle 身分的版本，用 `open` 啟動時可正常擷取音訊。
PROBE="build/AudioRouterProbe.app"
rm -rf "$PROBE"
mkdir -p "$PROBE/Contents/MacOS"
cp "$BIN_DIR/audiorouter" "$PROBE/Contents/MacOS/audiorouter"
cp Packaging/ProbeInfo.plist "$PROBE/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$PROBE"

# 裸執行檔也簽一下，至少在已獲授權的終端機裡跑得動。
codesign --force --sign "$IDENTITY" "$BIN_DIR/audiorouter"

echo
echo "已建立 $APP"
echo "診斷用 CLI bundle：$PROBE"
echo "裸 CLI：$BIN_DIR/audiorouter"
