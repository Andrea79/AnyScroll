#!/bin/bash
# Scrolls the window under the pointer at constant speeds with each engine, for
# scripts/smoothness.html (open it in the browser and leave the pointer over it).
#   ./scripts/smoothness.sh [speeds] [engines] [seconds]
# AnyScroll Dev needs Accessibility to post scroll events.
set -euo pipefail

cd "$(dirname "$0")/.."
SPEEDS="${1:-60,100,200}"
ENGINES="${2:-original,frames}"
SECONDS_PER_RUN="${3:-4}"
DEV_ID="io.github.andrea79.AnyScroll.dev"
APP="build/dev/AnyScroll Dev.app"

[ -d "$APP" ] || ./scripts/build_dev.sh > /dev/null
osascript -e "tell application id \"$DEV_ID\" to quit" 2>/dev/null || true

# The same settings for every run (the app engine follows them)
defaults write "$DEV_ID" scrollSensitivity -float 1.0
defaults write "$DEV_ID" invertScrollDirection -bool NO

echo "Leave the pointer over the test page; scrolling starts in 5 s"
# Started through Launch Services, so macOS checks the app's own Accessibility
# permission rather than that of the terminal it was started from
LOG="$(mktemp)"
open -W -n "$APP" --stdout "$LOG" --stderr /dev/null \
    --args --smooth-test --speeds "$SPEEDS" --engines "$ENGINES" --seconds "$SECONDS_PER_RUN" --delay 5
cat "$LOG"
rm -f "$LOG"
