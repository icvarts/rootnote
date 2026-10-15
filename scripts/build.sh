#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
output=${OUTPUT_ROOT:-"$root/.build/release"}
app="$output/Rootnote Resonance.app"
export MACOSX_DEPLOYMENT_TARGET=14.0
[[ ! -e "$app" ]] || { print -u2 "输出已存在，请使用新的 OUTPUT_ROOT：$app"; exit 73; }
command -v node >/dev/null
command -v pnpm >/dev/null
xcrun --find swiftc >/dev/null
# The glass APIs require a macOS 26 SDK; runtime fallbacks remain available.
sdk=$(xcrun --sdk macosx --show-sdk-version)
[[ ${sdk%%.*} -ge 26 ]] || { print -u2 "构建需要 macOS 26 SDK（Xcode 26 或相应命令行工具）。"; exit 69; }
pnpm --dir "$root/scene" install --frozen-lockfile
pnpm --dir "$root/scene" build
OUTPUT_ROOT="$output/compiler" zsh "$root/build-test-executable.sh"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/licenses"
cp "$output/compiler/RootnoteResonanceDesktop" "$app/Contents/MacOS/"
cp "$root/Info.plist" "$app/Contents/"
cp -R "$root/Resources/guard" "$app/Contents/Resources/"
cp -R "$root/scene/dist" "$app/Contents/Resources/scene"
cp "$root/LICENSE" "$root/ASSETS.md" "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/licenses/"
cp "$root/scene/node_modules/three/LICENSE" "$app/Contents/Resources/licenses/three-LICENSE"
xcrun swift "$root/Sources/MakePetIcon.swift" "$root/Assets/current-desktop-pet.png" "$output/icon.png"
for size in 128 256 512 1024; do
  sips -z "$size" "$size" "$output/icon.png" --out "$output/icon-$size.png" >/dev/null
done
xcrun swift "$root/Sources/PackICNS.swift" "$output/icon-128.png" "$output/icon-256.png" "$output/icon-512.png" "$output/icon-1024.png" "$app/Contents/Resources/RootnotePetIcon.icns"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print "已构建（本机临时签名，未公证）：$app"
