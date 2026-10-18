//
//  AnyScrollApp.swift
//  AnyScroll
//

import Cocoa
import QuartzCore
import ServiceManagement
import ApplicationServices

@main
@MainActor
enum AnyScrollMain {
    // NSApplication.delegate is weak, so keep the delegate alive here
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

/// Near a screen edge the pointer cannot move far enough to reach full speed
/// (upstream issue #12), so the distance in that direction is stretched to fit
/// the room that is left.
struct EdgeBoost {
    var up: CGFloat = 1
    var down: CGFloat = 1
    var left: CGFloat = 1
    var right: CGFloat = 1

    init() {}

    init(around point: NSPoint, screenFrames: [NSRect], deadZone: CGFloat, fullSpeedDistance: CGFloat) {
        func boost(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
            let room = Self.room(from: point, dx: dx, dy: dy, in: screenFrames,
                                 limit: deadZone + fullSpeedDistance) - deadZone
            return room >= fullSpeedDistance ? 1 : fullSpeedDistance / max(room, 15)
        }
        up = boost(0, 1)
        down = boost(0, -1)
        left = boost(-1, 0)
        right = boost(1, 0)
    }

    /// How far the pointer can travel from point in one direction before leaving every screen.
    private static func room(from point: NSPoint, dx: CGFloat, dy: CGFloat, in frames: [NSRect], limit: CGFloat) -> CGFloat {
        var distance: CGFloat = 0
        while distance < limit {
            let next = NSPoint(x: point.x + dx * (distance + 1), y: point.y + dy * (distance + 1))
            guard frames.contains(where: { NSMouseInRect(next, $0, false) }) else { break }
            distance += 1
        }
        return distance
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SettingsHost {
    var statusItem: NSStatusItem!
    let interceptor = ClickInterceptor()
    let scrollIndicator = ScrollIndicator()
    var trackpadMonitor: Any?

    // Scroll state
    var isAutoScrolling = false
    var anchor: NSPoint?               // where auto-scroll started, in screen coordinates
    var edgeBoost = EdgeBoost()
    var activeDirections: ScrollDirections = .vertical   // for the current auto-scroll
    var scrollWindowFrame: NSRect?     // window auto-scroll started in (screen coordinates)
    var scrollClock: DispatchSourceTimer?
    var lastTickTime: CFTimeInterval?
    var scrollRemainderX: CGFloat = 0  // fraction of a pixel carried to the next event
    var scrollRemainderY: CGFloat = 0
    var scrollSpeedX: CGFloat = 0      // current speeds, pixels per second
    var scrollSpeedY: CGFloat = 0
    private var debugFrame = 0
    #if DEBUG_LOG
    /// Where the pointer is; the Dev build's bench mode replaces it with a scripted path.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    #endif

    let deadZone: CGFloat = 5.0
    // Distance past the dead zone at which the speed curve reaches its cap
    let fullSpeedDistance: CGFloat = 50 * (30 / 2.5).squareRoot()
    /// Slowest auto-scroll in pixels per second, one pixel per frame at 60 Hz.
    let minimumSpeed: CGFloat = 60

    // Settings: setting one saves it, applies it and refreshes the menu and Settings window
    var activationMethod: ActivationMethod = .middleClick {
        didSet { settingChanged(activationMethod.rawValue, "activationMethod") { $0.configureInterceptor() } }
    }
    var optionScrollStartsAutoScroll = false {
        didSet { settingChanged(optionScrollStartsAutoScroll, "optionScrollStartsAutoScroll") { $0.updateTrackpadActivation() } }
    }
    var scrollSensitivity: Double = 1.0 {     // Default sensitivity multiplier
        didSet { settingChanged(scrollSensitivity, "scrollSensitivity") }
    }
    var releaseStopsHold = true {            // hold the button while moving, release to stop
        didSet { settingChanged(releaseStopsHold, "releaseStopsHold") { $0.configureInterceptor() } }
    }
    var excludedApps: [String] = [] {        // bundle ids where auto-scroll never starts
        didSet { settingChanged(excludedApps, "excludedApps") { $0.configureInterceptor() } }
    }
    var keyboardShortcut: KeyboardShortcut? {   // starts or stops auto-scroll at the pointer
        didSet {
            guard !isLoadingSettings else { return }
            if let keyboardShortcut {
                UserDefaults.standard.set(keyboardShortcut.storedValue, forKey: "keyboardShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "keyboardShortcut")
            }
            applyKeyboardShortcut()
            refreshSettingControls()
        }
    }
    var horizontalScrolling = false {         // off: only up and down
        didSet { settingChanged(horizontalScrolling, "horizontalScrolling") }
    }
    var appScrollDirections: [String: ScrollDirections] = [:] {   // bundle id -> directions
        didSet {
            settingChanged(appScrollDirections.mapValues(\.rawValue), "appScrollDirections")
        }
    }
    var isDirectionInverted = false {         // "Natural scrolling"; default is "up scrolls up"
        didSet { settingChanged(isDirectionInverted, "invertScrollDirection") }
    }
    var launchAtLogin = false {
        didSet { settingChanged(launchAtLogin, "launchAtLogin") { $0.updateLoginItemState() } }
    }
    private var isLoadingSettings = false

    private lazy var settingsWindow = SettingsWindowController(host: self)
    private let aboutWindow = AboutWindowController()
    private let hotKey = GlobalHotKey()

    // Menu items that show a setting
    private var startStopItem: NSMenuItem!
    private var horizontalItem: NSMenuItem!
    private let speedSlider = NSSlider()
    private let speedValue = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load user preferences
        let defaults = UserDefaults.standard
        isLoadingSettings = true
        isDirectionInverted = defaults.bool(forKey: "invertScrollDirection")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        scrollSensitivity = defaults.double(forKey: "scrollSensitivity")
        if scrollSensitivity == 0 { scrollSensitivity = 1.0 } // Default if not set
        optionScrollStartsAutoScroll = defaults.bool(forKey: "optionScrollStartsAutoScroll")
        horizontalScrolling = defaults.bool(forKey: "horizontalScrolling")
        appScrollDirections = ((defaults.dictionary(forKey: "appScrollDirections") as? [String: String]) ?? [:])
            .compactMapValues(ScrollDirections.init(rawValue:))
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        keyboardShortcut = KeyboardShortcut(storedValue: defaults.object(forKey: "keyboardShortcut"))
        releaseStopsHold = defaults.object(forKey: "releaseStopsHold") as? Bool ?? true
        if let savedMethod = defaults.string(forKey: "activationMethod"),
           let method = ActivationMethod(rawValue: savedMethod) {
            activationMethod = method
        }
        isLoadingSettings = false

        updateLoginItemState()

        // Shows the system prompt and adds the app to the Accessibility list if needed
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt,
        // which Swift 6 rejects as a global mutable variable
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        #if DEBUG_LOG
        if !Bench.isRequested && !SmoothTest.isRequested { _ = AXIsProcessTrustedWithOptions(options) }
        #else
        _ = AXIsProcessTrustedWithOptions(options)
        #endif

        setupMenuBar()

        interceptor.onStart = { [weak self] location in
            guard let self else { return }
            self.startAutoScroll(at: self.screenPoint(fromDisplay: location))
        }
        interceptor.onStop = { [weak self] in self?.stopAutoScroll() }
        configureInterceptor()
        interceptor.start()
        #if DEBUG_LOG
        Bench.runIfRequested(self)
        SmoothTest.runIfRequested(self)
        #endif

        updateTrackpadActivation()

        hotKey.onPress = { [weak self] slot in
            switch slot {
            case .toggle: self?.toggleAutoScrollFromMenu()
            case .stop: self?.stopAutoScroll()
            }
        }
        applyKeyboardShortcut()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAutoScroll()
    }

    func menuWillOpen(_ menu: NSMenu) {
        startStopItem.title = isAutoScrolling ? "Stop Auto-Scroll" : "Start Auto-Scroll"
    }

    // MARK: - Menu

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        startStopItem = NSMenuItem(title: "Start Auto-Scroll", action: #selector(toggleAutoScrollFromMenu), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)
        menu.addItem(NSMenuItem.separator())

        // Speed slider
        let speedLabel = NSTextField(labelWithString: "Speed")
        speedSlider.minValue = 0.2
        speedSlider.maxValue = 3.0
        speedSlider.controlSize = .small
        speedSlider.isContinuous = true
        speedSlider.target = self
        speedSlider.action = #selector(speedSliderChanged)
        speedValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        speedValue.alignment = .right
        let speedRow = NSStackView(views: [speedLabel, speedSlider, speedValue])
        speedRow.spacing = 8
        speedRow.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        speedRow.frame = NSRect(x: 0, y: 0, width: 250, height: 28)
        speedSlider.widthAnchor.constraint(equalToConstant: 130).isActive = true
        speedValue.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let speedItem = NSMenuItem()
        speedItem.view = speedRow
        menu.addItem(speedItem)

        horizontalItem = NSMenuItem(title: "Horizontal Scrolling", action: #selector(toggleHorizontalFromMenu), keyEquivalent: "")
        horizontalItem.target = self
        menu.addItem(horizontalItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "About AnyScroll", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit AnyScroll", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        refreshSettingControls()
    }

    /// Saves a changed setting, applies it, and updates every control that shows it.
    private func settingChanged<Value>(_ value: Value, _ key: String, apply: ((AppDelegate) -> Void)? = nil) {
        guard !isLoadingSettings else { return }
        UserDefaults.standard.set(value, forKey: key)
        apply?(self)
        refreshSettingControls()
    }

    private func refreshSettingControls() {
        guard statusItem != nil else { return }
        // Four arrows when horizontal scrolling is on, up and down only otherwise
        statusItem.button?.image = ScrollIndicator.statusBarImage(horizontal: horizontalScrolling)
        horizontalItem.state = horizontalScrolling ? .on : .off
        speedSlider.doubleValue = scrollSensitivity
        speedValue.stringValue = String(format: "%.1fx", scrollSensitivity)
        settingsWindow.refresh()
    }

    /// Registers the keyboard shortcut; if macOS uses it or refuses it, says so and clears it.
    private func applyKeyboardShortcut() {
        let usedBySystem = keyboardShortcut?.isUsedBySystem ?? false
        guard usedBySystem || !hotKey.register(keyboardShortcut, for: .toggle), let refused = keyboardShortcut else { return }
        hotKey.register(nil, for: .toggle)
        DispatchQueue.main.async { [weak self] in
            self?.keyboardShortcut = nil
            let alert = NSAlert()
            alert.messageText = "\(refused.displayName) can't be used"
            alert.informativeText = usedBySystem
                ? "macOS already uses this shortcut. Choose a different one in Settings."
                : "macOS didn't accept this shortcut. Choose a different one in Settings."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func configureInterceptor() {
        interceptor.configure(activationMethod: activationMethod, releaseStopsHold: releaseStopsHold,
                              excludedApps: Set(excludedApps))
    }

    // MARK: - Auto-scroll

    @objc func toggleAutoScrollFromMenu() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll(at: NSEvent.mouseLocation)
        }
    }

    /// `followWindow`: keep auto-scroll on the window under `point` (false only for the benchmark).
    func startAutoScroll(at point: NSPoint, followWindow: Bool = true) {
        tearDownScrolling()

        anchor = point
        let screens = NSScreen.screens.map(\.frame)
        let mainScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let window = followWindow ? AppUnderPointer.window(at: CGPoint(x: point.x, y: mainScreenTop - point.y)) : nil
        // Scrolling pauses outside this window, and the speed boost uses its edges
        // (where they are on screen), so full speed is reachable without leaving it
        scrollWindowFrame = window.map {
            NSRect(x: $0.bounds.minX, y: mainScreenTop - $0.bounds.maxY, width: $0.bounds.width, height: $0.bounds.height)
        }
        let visibleWindow = scrollWindowFrame.map { frame in screens.map { $0.intersection(frame) }.filter { !$0.isEmpty } }
        edgeBoost = EdgeBoost(around: point, screenFrames: visibleWindow.flatMap { $0.isEmpty ? nil : $0 } ?? screens,
                              deadZone: deadZone, fullSpeedDistance: fullSpeedDistance)
        scrollRemainderX = 0
        scrollRemainderY = 0
        scrollSpeedX = 0
        scrollSpeedY = 0
        lastTickTime = nil

        isAutoScrolling = true
        interceptor.setScrolling(true)
        // Esc stops auto-scroll; it is taken from other apps only while scrolling
        hotKey.register(GlobalHotKey.escape, for: .stop)
        activeDirections = directions(for: window?.bundleIdentifier)
        scrollIndicator.show(at: point, directions: activeDirections)
        startScrollClock()
    }

    func stopAutoScroll() {
        tearDownScrolling()
        interceptor.setScrolling(false)
    }

    private func tearDownScrolling() {
        scrollClock?.cancel()
        scrollClock = nil
        scrollIndicator.hide()
        hotKey.register(nil, for: .stop)
        isAutoScrolling = false
        anchor = nil
        scrollWindowFrame = nil
    }

    /// The per-app rule for this app, else the global setting.
    private func directions(for bundleIdentifier: String?) -> ScrollDirections {
        let global: ScrollDirections = horizontalScrolling ? .both : .vertical
        return bundleIdentifier.flatMap { appScrollDirections[$0] } ?? global
    }

    /// Posts each whole pixel when it is due rather than once per display frame.
    /// Events sent in step with the display reach a browser just as it draws, so some
    /// frames get none and the next gets two, which shows as a small judder.
    private func startScrollClock() {
        let clock = DispatchSource.makeTimerSource(queue: .main)
        clock.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scrollTick() }
        }
        scrollClock = clock
        clock.schedule(deadline: .now())
        clock.resume()
    }

    private func scrollTick() {
        let time = CACurrentMediaTime()
        #if DEBUG_LOG
        if let last = lastTickTime { Bench.stats?.frameIntervals.append(time - last) }
        #endif
        // Clamp so a stall (e.g. sleep) does not turn into one big jump
        let elapsed = lastTickTime.map { min(max(time - $0, 0), 0.05) } ?? 1.0 / 60
        lastTickTime = time
        performScroll(seconds: CGFloat(elapsed))
        guard isAutoScrolling else { return }

        // Next tick when the faster axis completes its next pixel: at least 60 times a
        // second so the anchor and speed follow the pointer, at most 180 (larger steps
        // beyond: as smooth as more events, for less CPU)
        func due(_ speed: CGFloat, _ remainder: CGFloat) -> Double {
            speed > 0 ? Double(max(1 - abs(remainder), 0) / speed) : .infinity
        }
        let wait = min(due(scrollSpeedX, scrollRemainderX), due(scrollSpeedY, scrollRemainderY))
        scrollClock?.schedule(deadline: .now() + min(max(wait, 1.0 / 180), 1.0 / 60), leeway: .milliseconds(1))
    }

    func performScroll(seconds: CGFloat) {
        guard let start = anchor else { return }
        #if DEBUG_LOG
        let current = pointerLocation()
        #else
        let current = NSEvent.mouseLocation
        #endif

        // Outside the window auto-scroll started in, pause until the pointer comes back
        if let frame = scrollWindowFrame, !frame.contains(current) {
            scrollIndicator.update(vertical: .none, horizontal: .none)
            scrollRemainderX = 0
            scrollRemainderY = 0
            scrollSpeedX = 0
            scrollSpeedY = 0
            return
        }

        let deltaX = current.x - start.x
        let deltaY = current.y - start.y

        let distanceX = activeDirections.allowsHorizontal ? max(0, abs(deltaX) - deadZone) : 0
        let distanceY = activeDirections.allowsVertical ? max(0, abs(deltaY) - deadZone) : 0
        // The arrows show where the page goes, so they flip with Natural scrolling
        let pointsUp = (deltaY > 0) != isDirectionInverted
        let pointsRight = (deltaX > 0) != isDirectionInverted
        scrollIndicator.update(vertical: distanceY == 0 ? .none : (pointsUp ? .up : .down),
                               horizontal: distanceX == 0 ? .none : (pointsRight ? .right : .left))

        let boostedX = distanceX * (deltaX > 0 ? edgeBoost.right : edgeBoost.left)
        let boostedY = distanceY * (deltaY > 0 ? edgeBoost.up : edgeBoost.down)

        // Flipped the default direction - now moving up scrolls up by default
        let directionMultiplier = isDirectionInverted ? 1.0 : -1.0  // Inverted the multiplier
        // wheel1 > 0 scrolls up, wheel2 > 0 scrolls left
        scrollSpeedX = scrollSpeed(forDistance: boostedX)
        scrollSpeedY = scrollSpeed(forDistance: boostedY)
        let amountY = (deltaY > 0 ? -1.0 : 1.0) * directionMultiplier * scrollSpeedY * seconds
        let amountX = (deltaX > 0 ? 1.0 : -1.0) * directionMultiplier * scrollSpeedX * seconds

        // Events carry whole pixels: keep the fraction for the next event so the
        // average speed is exact instead of being rounded away
        scrollRemainderX += amountX
        scrollRemainderY += amountY
        let wheelX = scrollRemainderX.rounded(.towardZero)
        let wheelY = scrollRemainderY.rounded(.towardZero)
        scrollRemainderX -= wheelX
        scrollRemainderY -= wheelY

        if wheelX == 0 && wheelY == 0 {
            return // don't scroll unless meaningful
        }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .pixel,
                                        wheelCount: 2,
                                        wheel1: Int32(wheelY),
                                        wheel2: Int32(wheelX),
                                        wheel3: 0) else { return }
        scrollEvent.flags = .maskNonCoalesced

        // Goes to the window under the pointer. Giving the event the anchor's location
        // instead would keep scrolling the clicked window, but macOS then moves the
        // pointer there; posting to the app's pid is ignored.
        scrollEvent.post(tap: .cgSessionEventTap)
        #if DEBUG_LOG
        Bench.stats?.events += 1
        #endif

        debugFrame += 1
        if debugFrame % 15 == 1 {
            DebugLog.write("frame \(debugFrame): pointer \(Int(current.x)),\(Int(current.y)) "
                           + "delta \(Int(deltaX)),\(Int(deltaY)) posted \(Int(wheelX)),\(Int(wheelY))")
        }
    }

    /// Scroll speed in pixels per second for a distance from the anchor (dead zone already removed).
    func scrollSpeed(forDistance distance: CGFloat) -> CGFloat {
        // Quadratic acceleration: scrollSpeed grows faster as distance increases
        let acceleration = pow(distance / 50, 2.0) // scale distance into a nice curve
        let maxScrollSpeed: CGFloat = 30.00
        let scrollSpeed = min(acceleration * 2.5, maxScrollSpeed) // scaled + capped

        // Apply sensitivity multiplier with exponential scaling for values < 1.0
        // This makes slower speeds MUCH slower but still usable
        let adjustedSensitivity: CGFloat
        if scrollSensitivity < 1.0 {
            // Exponential scaling for slow speeds, but not too extreme
            // 0.1 becomes ~0.03, 0.2 becomes ~0.08, 0.5 becomes ~0.35
            adjustedSensitivity = CGFloat(pow(scrollSensitivity, 1.5))
        } else {
            // Linear scaling for faster speeds
            adjustedSensitivity = CGFloat(scrollSensitivity)
        }

        // The curve was tuned in pixels per 10 ms step
        let perStep = scrollSpeed * adjustedSensitivity

        // Dynamic threshold based on sensitivity - allow very slow scrolling at low sensitivities
        let threshold = min(0.1, adjustedSensitivity * 0.5)
        // Events carry whole pixels, so below about one pixel per frame at 60 Hz the
        // page moves in visible steps: once scrolling, never go slower than that
        return perStep < threshold ? 0 : max(perStep * 100, minimumSpeed)
    }

    // Screen coordinates have their origin at the bottom-left of the main display,
    // display (CGEvent) coordinates at its top-left.
    func screenPoint(fromDisplay point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    // MARK: - Trackpad activation

    func updateTrackpadActivation() {
        if let monitor = trackpadMonitor {
            NSEvent.removeMonitor(monitor)
            trackpadMonitor = nil
        }
        guard optionScrollStartsAutoScroll else { return }

        // Starts only on Option held at the beginning of a two-finger trackpad scroll;
        // mouse wheels (no precise deltas) and scrolls already under way are ignored
        trackpadMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, !self.isAutoScrolling,
                  event.modifierFlags.contains(.option),
                  event.hasPreciseScrollingDeltas,
                  event.phase == .began else { return }
            let point = NSEvent.mouseLocation
            let displayPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            if let app = AppUnderPointer.bundleIdentifier(at: displayPoint), self.excludedApps.contains(app) { return }
            self.startAutoScroll(at: point)
        }
    }

    // MARK: - Menu actions

    @objc func speedSliderChanged() {
        scrollSensitivity = speedSlider.doubleValue
    }

    @objc func toggleHorizontalFromMenu() {
        horizontalScrolling.toggle()
    }

    @objc func showSettings() {
        settingsWindow.show()
    }

    func updateLoginItemState() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            print("Failed to update login item: \(error.localizedDescription)")
        }
    }

    @objc func showAbout() {
        aboutWindow.show(activationMethod: activationMethod, shortcut: keyboardShortcut?.displayName,
                         horizontalScrolling: horizontalScrolling,
                         optionTrackpad: optionScrollStartsAutoScroll, releaseStopsHold: releaseStopsHold)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
