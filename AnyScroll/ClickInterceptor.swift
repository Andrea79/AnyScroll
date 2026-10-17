//
//  ClickInterceptor.swift
//  AnyScroll
//
//  Catches the mouse clicks that start and stop auto-scroll so they do not also
//  reach the app under the pointer (NSEvent monitors can only watch events).
//  The event tap runs on its own thread: an active tap on the main thread would
//  delay every click on the Mac whenever the main thread is busy.
//

import Cocoa

enum ActivationMethod: String, CaseIterable {
    case middleClick = "Middle Click"
    case shiftMiddleClick = "Shift + Middle Click"
    case cmdMiddleClick = "Cmd + Middle Click"
    case optionMiddleClick = "Option + Middle Click"
    case button4 = "Mouse Button 4"
    case button5 = "Mouse Button 5"
    case doubleMiddleClick = "Double Middle Click"

    var buttonNumber: Int64 {
        switch self {
        case .middleClick, .shiftMiddleClick, .cmdMiddleClick, .optionMiddleClick, .doubleMiddleClick:
            return 2
        case .button4:
            return 3
        case .button5:
            return 4
        }
    }

    var modifierFlags: NSEvent.ModifierFlags? {
        switch self {
        case .shiftMiddleClick:
            return .shift
        case .cmdMiddleClick:
            return .command
        case .optionMiddleClick:
            return .option
        default:
            return nil
        }
    }
}

final class ClickInterceptor: @unchecked Sendable {
    /// Called on the main thread with the click location in global display
    /// coordinates (origin at the top-left of the main display).
    var onStart: (@MainActor (CGPoint) -> Void)?
    var onStop: (@MainActor () -> Void)?

    // Shared with the main thread, guarded by lock
    private let lock = NSLock()
    private var activationMethod: ActivationMethod = .middleClick
    private var releaseStopsHold = true
    private var excludedApps = Set<String>()        // bundle ids where auto-scroll never starts
    private var isScrolling = false

    // Only used on the tap thread
    private var tap: CFMachPort?
    private var swallowedMouseUps = Set<Int64>()  // buttons whose mouse-up must be swallowed too
    private var lastActivationClick: TimeInterval?
    private var heldPress: HeldPress?               // activation button still down after starting

    /// The press that started auto-scroll, while its button is still down.
    private struct HeldPress {
        let button: Int64
        let origin: CGPoint
        var moved = false
        var drags = 0
    }

    /// Moving further than this with the button down makes it a hold:
    /// releasing the button then stops auto-scroll.
    private let holdDistance: CGFloat = 10

    func configure(activationMethod: ActivationMethod, releaseStopsHold: Bool, excludedApps: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        self.activationMethod = activationMethod
        self.releaseStopsHold = releaseStopsHold
        self.excludedApps = excludedApps
    }

    func setScrolling(_ scrolling: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isScrolling = scrolling
    }

    func start() {
        let thread = Thread { [self] in runTapLoop() }
        thread.name = "AnyScroll click interceptor"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func runTapLoop() {
        // Without Accessibility permission there is no tap; keep trying so granting it
        // in System Settings takes effect without restarting the app.
        var created: CFMachPort?
        while created == nil {
            if AXIsProcessTrusted() {
                created = makeTap()
            }
            if created == nil {
                Thread.sleep(forTimeInterval: 2)
            }
        }
        guard let tap = created else { return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func makeTap() -> CFMachPort? {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let interceptor = Unmanaged<ClickInterceptor>.fromOpaque(refcon!).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        return CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: .defaultTap,
                                 eventsOfInterest: mask,
                                 callback: callback,
                                 userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Returns nil to swallow the event, or the event to let it through.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        case .otherMouseDragged:
            // Watch the drag to tell a hold from a click, but let it through: swallowing
            // drags also stops the pointer, so auto-scroll would never see it move.
            // The app underneath never saw the press, so it ignores the drag.
            guard var press = heldPress, press.button == button else { return passThrough }
            press.moved = press.moved || distance(press.origin, event.location) > holdDistance
            press.drags += 1
            heldPress = press
            if press.drags % 10 == 1 {
                DebugLog.write("drag #\(press.drags) at \(Int(event.location.x)),\(Int(event.location.y)) "
                               + "cursor \(cursorText()) moved=\(press.moved)")
            }
            return passThrough
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let press = heldPress, press.button == button {
                heldPress = nil
                lock.lock()
                let stopOnRelease = releaseStopsHold && isScrolling
                lock.unlock()
                // Held and moved: releasing ends auto-scroll. A plain click keeps it going.
                let held = press.moved || distance(press.origin, event.location) > holdDistance
                DebugLog.write("up after \(press.drags) drags, held=\(held), stops=\(stopOnRelease && held)")
                if stopOnRelease, held {
                    stop()
                }
            }
            return swallowedMouseUps.remove(button) != nil ? nil : passThrough
        default:
            break
        }

        lock.lock()
        let method = activationMethod
        let scrolling = isScrolling
        lock.unlock()

        let handled: Bool
        if scrolling {
            // Any click ends auto-scroll, including the activation button
            heldPress = nil
            stop()
            handled = true
        } else if type == .otherMouseDown, button == method.buttonNumber, isActivation(event, method: method),
                  !isExcludedApp(at: event.location) {
            setScrolling(true)
            let location = event.location
            heldPress = HeldPress(button: button, origin: location)
            DebugLog.write("start at \(Int(location.x)),\(Int(location.y))")
            DispatchQueue.main.async { self.onStart?(location) }
            handled = true
        } else {
            handled = false
        }

        guard handled else { return passThrough }
        swallowedMouseUps.insert(button)
        return nil
    }

    /// Whether the window under the click belongs to an app the user excluded, which then
    /// gets the click itself (e.g. to pan with the middle button).
    private func isExcludedApp(at point: CGPoint) -> Bool {
        lock.lock()
        let excluded = excludedApps
        lock.unlock()
        guard !excluded.isEmpty, let app = AppUnderPointer.bundleIdentifier(at: point) else { return false }
        let isExcluded = excluded.contains(app)
        DebugLog.write("click over \(app), excluded=\(isExcluded)")
        return isExcluded
    }

    private func stop() {
        setScrolling(false)
        DispatchQueue.main.async { self.onStop?() }
    }

    private func cursorText() -> String {
        guard let p = CGEvent(source: nil)?.location else { return "?" }
        return "\(Int(p.x)),\(Int(p.y))"
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Whether this press of the activation button should start auto-scroll.
    private func isActivation(_ event: CGEvent, method: ActivationMethod) -> Bool {
        if let required = method.modifierFlags {
            guard NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).contains(required) else { return false }
        }
        guard method == .doubleMiddleClick else { return true }

        // The first click of a double click goes through; the second one starts
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastActivationClick, now - last < 0.5 {
            lastActivationClick = nil
            return true
        }
        lastActivationClick = now
        return false
    }
}
