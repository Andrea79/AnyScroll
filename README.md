# AnyScroll for Mac

<img src="img/anyscroll-icon.png" width="100" alt="AnyScroll icon">

**Windows-style auto-scroll in any direction.**

Press the middle mouse button where you want to scroll and an anchor appears.
Move the pointer away from it and the page scrolls by itself: the further you
go, the faster it scrolls. Click any button to stop. Your fingers rest; no
wheel to roll, nothing to hold down.

## Features

- **Visible anchor** where auto-scroll starts, with the active direction highlighted.
- **Click or hold**: a quick click keeps scrolling until you click again; or
  hold the button while you move and let go to stop (can be turned off).
- **Up and down, or any direction**: turn on horizontal scrolling to also
  scroll sideways and diagonally.
- **Clicks stay with AnyScroll**: the click that starts or stops scrolling never
  reaches the app underneath, so it does not open links or press buttons.
- **Smooth**: scrolls once per display frame (60 or 120 Hz), with sub-pixel
  precision at slow speeds.
- **Full speed near screen edges**: the speed builds up sooner when there is
  little room left to move the pointer.
- **Choose how to start**: middle click, Shift/Cmd/Option + middle click,
  double middle click, or a side button. Optionally Option + two-finger
  trackpad scroll.
- **Exclude apps** that use the middle button themselves, such as panning in
  design or 3D apps: AnyScroll leaves the click to them.
- **Adjustable speed** (0.2x to 3.0x), natural scrolling, open at login.
- **Never goes online**: no network access, no data collected or sent.
- Light: about 30 MB of memory and no CPU while idle.

## Requirements

- macOS 13 Ventura or later, on Apple Silicon or Intel (universal app).
- A mouse with a middle button or side buttons (or a trackpad, with the
  Option + scroll option).
- Accessibility permission, which macOS asks for on first launch
  (System Settings › Privacy & Security › Accessibility). AnyScroll needs it to
  see the clicks that start and stop scrolling and to send scroll events.

## Build

The app builds with the Swift compiler from Xcode; no Xcode project is needed.

```bash
./scripts/build_dev.sh release   # build/release/AnyScroll.app, to install
./scripts/build_dev.sh           # build/dev/AnyScroll Dev.app, for testing
```

The Dev build has its own bundle id, so it can run next to the installed app
with separate settings, and writes diagnostics to `~/Library/Logs/AnyScroll Dev.log`. The builds are signed ad hoc: after each rebuild macOS
treats the app as new and Accessibility must be granted again.

To redraw the app icon at every size: `swift scripts/make_icon.swift`.
To measure CPU, wakeups, energy and memory of the running app:
`./scripts/profile.sh 30 idle` (start auto-scroll while it runs to measure scrolling).
For a repeatable comparison between versions, `./scripts/bench.sh` runs the Dev
build with a scripted pointer on every screen and appends the results to
`bench/results.csv`, which stays on your Mac (it is not tracked by git).

## How it was made

AnyScroll was made by Andrea79 with [Claude Code](https://claude.com/claude-code),
Anthropic's AI coding assistant. All of the code, including the tools in
`scripts/`, was written by Claude under Andrea79's direction. Andrea79 came up
with the idea, made the design decisions, and tested and debugged the app on
real hardware. Commits written with Claude carry a `Co-Authored-By: Claude` line.

## Credits and license

AnyScroll is based on [Scrollapp](https://github.com/fromis-9/scrollapp) by
fromis-9, and was modified by Andrea79 in 2026: new anchor indicator,
four-direction scrolling, a rewritten scroll engine, new icon, About and
Settings windows.

Free software under the [GNU General Public License v3.0](LICENSE).
