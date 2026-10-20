#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h}
output_root=${OUTPUT_ROOT:-"$project_dir/.build/tests"}
mkdir -p "$output_root/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$output_root/ModuleCache"
export SWIFT_MODULECACHE_PATH="$output_root/ModuleCache"
xcrun clang -fobjc-arc -fblocks -c "$project_dir/Sources/PerformanceCollector.m" -o "$output_root/PerformanceCollector.o" -framework Foundation
cp "$project_dir/Sources/RootnoteResonanceDesktop.swift" "$output_root/main.swift"
xcrun swiftc "$output_root/main.swift" \
  "$project_dir/Sources/CompanionVisibility.swift" \
  "$project_dir/Sources/PetRiskBeacon.swift" \
  "$project_dir/Sources/ApprovalBridge.swift" \
  "$project_dir/Sources/RootnotePanelStore.swift" \
  "$project_dir/Sources/SidebarQuota.swift" \
  "$project_dir/Sources/SidebarQuotaAcceptance.swift" \
  "$output_root/PerformanceCollector.o" \
  -import-objc-header "$project_dir/Sources/PerformanceCollector.h" \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -framework Foundation -framework QuartzCore -framework WebKit \
  -o "$output_root/RootnoteResonanceDesktop"
print "$output_root/RootnoteResonanceDesktop"
