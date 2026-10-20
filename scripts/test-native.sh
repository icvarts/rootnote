#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
output=${OUTPUT_ROOT:-"$root/.build/tests"}
OUTPUT_ROOT="$output" zsh "$root/build-test-executable.sh"
export ROOTNOTE_RESOURCES="$root/Resources"
export ROOTNOTE_PANEL_STATE="$output/isolated-panel-state"
for mode in self-test visibility-self-test beacon-self-test approval-self-test idle-policy-self-test event-parser-self-test panel-data-self-test sidebar-quota-self-test; do
  "$output/RootnoteResonanceDesktop" "--$mode"
done
print "原生离线逻辑测试完成；未启动常驻应用、读取账号额度或更改 Codex。"
