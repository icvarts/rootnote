#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
destination="$HOME/.codex/pets/rootnote-resonance"
[[ ! -e "$destination" ]] || { print -u2 "宠物目录已存在，本脚本不会覆盖：$destination"; exit 73; }
mkdir -p "$HOME/.codex/pets"
ditto "$root/pets/rootnote-resonance" "$destination"
print "已复制宠物素材：$destination"
print "请在支持自定义宠物的 Codex 客户端中手动选择 Rootnote；未更改客户端设置。"
