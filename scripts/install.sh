#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
source_app=${1:-"$root/.build/release/Rootnote Resonance.app"}
destination="$HOME/Applications/Rootnote Resonance.app"
[[ -d "$source_app/Contents/MacOS" ]] || { print -u2 "请先构建应用，或传入完整 .app 路径。"; exit 66; }
[[ ! -e "$destination" ]] || { print -u2 "已存在 Rootnote；为保护设置及恢复路径，本脚本不覆盖已有版本。"; exit 73; }
codesign --verify --deep --strict "$source_app"
mkdir -p "$HOME/Applications"
ditto "$source_app" "$destination"
print "已安装：$destination"
print "请在 Finder 中手动打开。未启动应用，未添加登录项，未修改 Codex。"
