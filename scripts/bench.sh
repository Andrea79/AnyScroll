#!/bin/bash
# Scripted performance run of the Dev build on every screen; appends one line per
# screen to bench/results.csv so versions can be compared.
#   ./scripts/bench.sh [scroll seconds] [label]
# Needs no permissions and does not touch the installed AnyScroll: the bench copy
# cannot catch clicks, it only scrolls with a scripted pointer (an anchor appears
# in the middle of each screen for a while).
set -euo pipefail

cd "$(dirname "$0")/.."
SCROLL_SECONDS="${1:-20}"
LABEL="${2:-$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- AnyScroll scripts || echo +changes)}"
DEV_ID="io.github.andrea79.AnyScroll.dev"
BIN="build/dev/AnyScroll Dev.app/Contents/MacOS/AnyScroll"

./scripts/build_dev.sh > /dev/null
osascript -e "tell application id \"$DEV_ID\" to quit" 2>/dev/null || true

# The same settings for every run
defaults write "$DEV_ID" scrollSensitivity -float 1.0
defaults write "$DEV_ID" horizontalScrolling -bool NO
defaults write "$DEV_ID" invertScrollDirection -bool NO
defaults write "$DEV_ID" excludedApps -array com.apple.Preview
defaults write "$DEV_ID" launchAtLogin -bool NO

mkdir -p bench
for SCREEN in 0 1 2 3; do
    "$BIN" --bench "$SCROLL_SECONDS" --screen "$SCREEN" --label "$LABEL" --out bench/results.csv \
        > /dev/null 2>&1 || break
done

column -s, -t bench/results.csv | tail -n 6
