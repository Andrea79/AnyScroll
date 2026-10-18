//
//  SmoothTest.swift
//  AnyScroll
//
//  Constant-speed scrolling for scripts/smoothness.sh, in the Dev build only (-D DEBUG_LOG):
//
//    AnyScroll --smooth-test [--engines a,b] [--speeds 60,100] [--seconds 4] [--delay 5]
//
//  Scrolls the window under the pointer at each speed (pixels per second) with each
//  engine, one run after the other with a pause between, so scripts/smoothness.html
//  records every run separately. Engines:
//    app       AnyScroll itself, its pointer held where it gives that speed
//    original  Scrollapp: a 100 Hz timer posting the per-tick amount cut to whole pixels
//    frames    one event per display frame, fractions carried over (earlier AnyScroll)
//    half      as frames, but each event posted half a frame later
//    timer:N   a timer at N Hz, fractions carried over
//    pixel     the next event when the next whole pixel is due (at most 250 Hz); AnyScroll caps it at 180
//

#if DEBUG_LOG
import Cocoa

@MainActor
enum SmoothTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--smooth-test") }

    private static var engine = ""
    private static var speed: Double = 0
    private static var remainder: Double = 0
    private static var lastTime: CFTimeInterval?
    private static var direction: Double = -1  // -1 scrolls down; runs alternate so short pages last
    private static weak var app: AppDelegate?

    static func runIfRequested(_ app: AppDelegate) {
        self.app = app
        guard isRequested else { return }
        let engines = (value(after: "--engines") ?? "original,frames").split(separator: ",").map(String.init)
        let speeds = (value(after: "--speeds") ?? "100,200").split(separator: ",").compactMap { Double($0) }
        let seconds = value(after: "--seconds").flatMap(Double.init) ?? 4
        let delay = value(after: "--delay").flatMap(Double.init) ?? 5
        Task {
            await pause(delay)
            let point = NSEvent.mouseLocation
            let display = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            print("accessibility: \(AXIsProcessTrusted()), under pointer: \(AppUnderPointer.bundleIdentifier(at: display) ?? "none")")
            var run = 1
            for speed in speeds {
                for engine in engines {
                    print("run \(run): \(engine) \(Int(speed)) px/s")
                    await scroll(engine: engine, speed: speed, seconds: seconds)
                    await pause(2.5)  // the page ends a run after 1 s without wheel events
                    direction = -direction
                    run += 1
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func scroll(engine: String, speed: Double, seconds: Double) async {
        self.engine = engine
        self.speed = speed
        remainder = 0
        lastTime = nil
        var stop: () -> Void = {}
        switch engine {
        case "app":
            guard let app else { return }
            // The pointer distance past the dead zone that gives this speed (the
            // smallest one, which is inside the flat part at the minimum speed)
            var low: CGFloat = 0, high: CGFloat = 1000
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if app.scrollSpeed(forDistance: mid) >= speed { high = mid } else { low = mid }
            }
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            let anchor = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            // Pointer above the anchor scrolls up
            let offset = (app.deadZone + high + 0.5) * (direction < 0 ? -1 : 1)
            app.pointerLocation = { NSPoint(x: anchor.x, y: anchor.y + offset) }
            app.startAutoScroll(at: anchor, followWindow: false)
            stop = {
                app.stopAutoScroll()
                app.pointerLocation = { NSEvent.mouseLocation }
            }
        case "original":
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                MainActor.assumeIsolated { tickOriginal() }
            }
            RunLoop.main.add(timer, forMode: .common)
            stop = { timer.invalidate() }
        case let name where name.hasPrefix("timer:"):
            let hz = Double(name.dropFirst(6)) ?? 240
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now(), repeating: 1 / hz, leeway: .nanoseconds(0))
            timer.setEventHandler { MainActor.assumeIsolated { advance(to: CACurrentMediaTime()) } }
            timer.resume()
            stop = { timer.cancel() }
        case "pixel":
            var running = true
            func tick() {
                guard running else { return }
                advance(to: CACurrentMediaTime())
                // Time until the carried fraction reaches the next whole pixel
                let due = (1 - abs(remainder)) / max(speed, 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + min(max(due, 0.004), 0.05), qos: .userInteractive) {
                    MainActor.assumeIsolated { tick() }
                }
            }
            tick()
            stop = { running = false }
        default:
            guard #available(macOS 14.0, *) else { return }
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
            let link = screen.displayLink(target: FrameTarget.shared, selector: #selector(FrameTarget.frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            stop = { link.invalidate() }
        }
        await pause(seconds)
        stop()
    }

    // Scrollapp's performScroll at a constant amount per 10 ms tick
    private static func tickOriginal() {
        let amount = speed / 100
        guard amount >= 0.1 else { return }
        post(Int32(direction * amount))
    }

    fileprivate static func frame(at time: CFTimeInterval, duration: CFTimeInterval) {
        if engine == "half" {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2, qos: .userInteractive) {
                MainActor.assumeIsolated { advance(to: CACurrentMediaTime()) }
            }
        } else {
            advance(to: time)
        }
    }

    private static func advance(to time: CFTimeInterval) {
        let elapsed = lastTime.map { min(max(time - $0, 0), 0.05) } ?? 1.0 / 60
        lastTime = time
        remainder += direction * speed * elapsed
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        if whole != 0 { post(Int32(whole)) }
    }

    private static func post(_ pixels: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.flags = .maskNonCoalesced
        event.post(tap: .cgSessionEventTap)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

@MainActor
private final class FrameTarget: NSObject {
    static let shared = FrameTarget()
    @available(macOS 14.0, *)
    @objc func frame(_ link: CADisplayLink) { SmoothTest.frame(at: link.timestamp, duration: link.targetTimestamp - link.timestamp) }
}
#endif
