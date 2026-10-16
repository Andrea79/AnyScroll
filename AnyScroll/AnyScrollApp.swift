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
    var displayLink: NSObject?         // CADisplayLink (macOS 14+)
    var fallbackTimer: Timer?          // before macOS 14
    var lastFrameTime: CFTimeInterval?
    var scrollRemainderX: CGFloat = 0  // sub-pixel scroll carried to the next frame
    var scrollRemainderY: CGFloat = 0
    private var debugFrame = 0

    let deadZone: CGFloat = 5.0
    // Distance past the dead zone at which the speed curve reaches its cap
    let fullSpeedDistance: CGFloat = 50 * (30 / 2.5).squareRoot()

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
    var horizontalScrolling = false {         // off: only up and down
        didSet { settingChanged(horizontalScrolling, "horizontalScrolling") }
    }
    var isDirectionInverted = false {         // Default is "up scrolls up"
        didSet { settingChanged(isDirectionInverted, "invertScrollDirection") }
    }
    var launchAtLogin = false {
        didSet { settingChanged(launchAtLogin, "launchAtLogin") { $0.updateLoginItemState() } }
    }
    private var isLoadingSettings = false

    private lazy var settingsWindow = SettingsWindowController(host: self)
    private let aboutWindow = AboutWindowController()

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
        _ = AXIsProcessTrustedWithOptions(options)

        setupMenuBar()

        interceptor.onStart = { [weak self] location in
            guard let self else { return }
            self.startAutoScroll(at: self.screenPoint(fromDisplay: location))
        }
        interceptor.onStop = { [weak self] in self?.stopAutoScroll() }
        configureInterceptor()
        interceptor.start()

        updateTrackpadActivation()
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

    private func configureInterceptor() {
        interceptor.configure(activationMethod: activationMethod, releaseStopsHold: releaseStopsHold)
    }

    // MARK: - Auto-scroll

    @objc func toggleAutoScrollFromMenu() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll(at: NSEvent.mouseLocation)
        }
    }

    func startAutoScroll(at point: NSPoint) {
        tearDownScrolling()

        anchor = point
        edgeBoost = EdgeBoost(around: point, screenFrames: NSScreen.screens.map(\.frame),
                              deadZone: deadZone, fullSpeedDistance: fullSpeedDistance)
        scrollRemainderX = 0
        scrollRemainderY = 0
        lastFrameTime = nil

        isAutoScrolling = true
        interceptor.setScrolling(true)
        scrollIndicator.show(at: point, horizontal: horizontalScrolling)
        startFrameClock(at: point)
    }

    func stopAutoScroll() {
        tearDownScrolling()
        interceptor.setScrolling(false)
    }

    private func tearDownScrolling() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        scrollIndicator.hide()
        isAutoScrolling = false
        anchor = nil
    }

    /// Scrolls once per frame of the display auto-scroll started on, so every frame
    /// moves by an even amount (a fixed 100 Hz timer beats against 60/120 Hz screens).
    private func startFrameClock(at point: NSPoint) {
        if #available(macOS 14.0, *),
           let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(displayFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(fallbackFrame),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    @available(macOS 14.0, *)
    @objc private func displayFrame(_ link: CADisplayLink) {
        scrollFrame(at: link.timestamp)
    }

    @objc private func fallbackFrame() {
        scrollFrame(at: CACurrentMediaTime())
    }

    private func scrollFrame(at time: CFTimeInterval) {
        // Clamp so a stall (e.g. display sleep) does not turn into one big jump
        let elapsed = lastFrameTime.map { min(max(time - $0, 0), 0.05) } ?? 1.0 / 60
        lastFrameTime = time
        performScroll(seconds: CGFloat(elapsed))
    }

    func performScroll(seconds: CGFloat) {
        guard let start = anchor else { return }
        let current = NSEvent.mouseLocation
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y

        let distanceX = horizontalScrolling ? max(0, abs(deltaX) - deadZone) : 0
        let distanceY = max(0, abs(deltaY) - deadZone)
        scrollIndicator.update(vertical: distanceY == 0 ? .none : (deltaY > 0 ? .up : .down),
                               horizontal: distanceX == 0 ? .none : (deltaX > 0 ? .right : .left))

        let boostedX = distanceX * (deltaX > 0 ? edgeBoost.right : edgeBoost.left)
        let boostedY = distanceY * (deltaY > 0 ? edgeBoost.up : edgeBoost.down)

        // Flipped the default direction - now moving up scrolls up by default
        let directionMultiplier = isDirectionInverted ? 1.0 : -1.0  // Inverted the multiplier
        // wheel1 > 0 scrolls up, wheel2 > 0 scrolls left
        let amountY = (deltaY > 0 ? -1.0 : 1.0) * directionMultiplier * scrollSpeed(forDistance: boostedY) * seconds
        let amountX = (deltaX > 0 ? 1.0 : -1.0) * directionMultiplier * scrollSpeed(forDistance: boostedX) * seconds

        // Events carry whole pixels: keep the fraction for the next frame so slow
        // scrolling stays smooth instead of being rounded away
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
        return perStep < threshold ? 0 : perStep * 100
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
            self.startAutoScroll(at: NSEvent.mouseLocation)
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
        aboutWindow.show(activationMethod: activationMethod, horizontalScrolling: horizontalScrolling,
                         optionTrackpad: optionScrollStartsAutoScroll, releaseStopsHold: releaseStopsHold)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
