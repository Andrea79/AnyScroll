#!/bin/bash
# Measures the running AnyScroll: CPU, idle wakeups, energy impact, threads
# and memory, sampled once a second.
#   ./scripts/profile.sh [seconds] [label] [app]
#   ./scripts/profile.sh 30 idle                 # the installed AnyScroll
#   ./scripts/profile.sh 20 scrolling "AnyScroll Dev"
# Needs no admin rights. While it runs, start auto-scroll yourself if you want
# the "scrolling" numbers.
set -euo pipefail

SECONDS_TO_RUN="${1:-30}"
LABEL="${2:-idle}"
APP="${3:-AnyScroll}"

PID="$(pgrep -f "/$APP.app/Contents/MacOS/" | head -1 || true)"
if [ -z "$PID" ]; then
    echo "$APP is not running" >&2
    exit 1
fi

echo "== $APP (pid $PID), $LABEL, $SECONDS_TO_RUN s"

# top: the first sample has no CPU history, so take one extra and drop it
top -l "$((SECONDS_TO_RUN + 1))" -s 1 -pid "$PID" -stats pid,cpu,idlew,power,th,mem 2>/dev/null \
    | awk -v pid="$PID" '
        $1 == pid { n++; if (n == 1) next
                    cpu += $2; if ($2 > maxcpu) maxcpu = $2
                    if (k0 == "") k0 = $3; w1 = $3   # idle wakeups are a running total
                    power += $4; if ($4 > maxpower) maxpower = $4
                    threads = $5; mem = $6 }
        END { k = n - 1
              printf "CPU %%          avg %.2f   max %.1f\n", cpu / k, maxcpu
              printf "wakeups/s      avg %.1f\n", (w1 - k0) / (k > 1 ? k - 1 : 1)
              printf "energy impact  avg %.2f   max %.1f\n", power / k, maxpower
              printf "threads        %s\n", threads
              printf "memory (top)   %s\n", mem }'

# Memory that is really AnyScroll's own (top also counts shared system libraries)
footprint -p "$PID" 2>/dev/null \
    | awk 'match($0, /Footprint: [0-9.]+ [KMG]B/) { print "footprint     ", substr($0, RSTART + 11, RLENGTH - 11); exit }'
