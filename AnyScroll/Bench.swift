//
//  Bench.swift
//  AnyScroll
//
//  Scripted usage for scripts/bench.sh, in the Dev build only (-D DEBUG_LOG):
//
//    AnyScroll --bench <seconds> [--screen N] [--label text] [--out results.csv]
//
//  Measures the app at rest, then auto-scrolls on screen N with a scripted pointer
//  path for <seconds>, then opens and closes Settings, appends one CSV line and quits.
//

#if DEBUG_LOG
import Cocoa

@MainActor
enum Bench {
    struct Stats {
        var events = 0
        var frameIntervals: [Double] = []
    }

    /// Set while the scroll phase runs; the app adds frames and posted events to it.
    static var stats: Stats?

    static var isRequested: Bool { CommandLine.arguments.contains("--bench") }

    static let csvHeader = "date,version,label,screen,hz,launch_mb,idle_cpu_pct,idle_wakeups_s,"
        + "scroll_cpu_pct,scroll_wakeups_s,fps,frame_ms_p50,frame_ms_p95,events_s,exclusion_lookup_ms,after_settings_mb"

    private static let idleSeconds = 10.0

    static func runIfRequested(_ app: AppDelegate) {
        guard isRequested else { return }
        let seconds = value(after: "--bench").flatMap(Double.init) ?? 20
        let screenIndex = value(after: "--screen").flatMap(Int.init) ?? 0
        guard screenIndex < NSScreen.screens.count else {
            print("no screen \(screenIndex)")
            exit(2)
        }
        Task { await run(app, seconds: seconds, screen: NSScreen.screens[screenIndex], index: screenIndex) }
    }

    private static func run(_ app: AppDelegate, seconds: Double, screen: NSScreen, index: Int) async {
        await pause(2)  // let the launch settle
        let launchMB = footprintMB()

        let idle = await measure { await pause(idleSeconds) }

        // The scripted pointer swings up to 120 pt above and below the anchor every 8 s,
        // passing through the dead zone, so slow, fast and stopped scrolling all occur
        let anchor = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        let start = CACurrentMediaTime()
        app.pointerLocation = {
            let t = CACurrentMediaTime() - start
            return NSPoint(x: anchor.x, y: anchor.y + 120 * sin(2 * .pi * t / 8))
        }
        stats = Stats()
        let scroll = await measure {
            app.startAutoScroll(at: anchor)
            await pause(seconds)
            app.stopAutoScroll()
        }
        let result = stats ?? Stats()
        stats = nil
        app.pointerLocation = { NSEvent.mouseLocation }

        // Cost of finding the app under the pointer, done on each click that starts scrolling
        let displayAnchor = CGPoint(x: anchor.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - anchor.y)
        let lookupStart = CACurrentMediaTime()
        for _ in 0..<50 { _ = AppUnderPointer.bundleIdentifier(at: displayAnchor) }
        let lookupMs = (CACurrentMediaTime() - lookupStart) / 50 * 1000

        app.showSettings()
        await pause(2)
        NSApp.windows.first { $0.title == "AnyScroll Settings" }?.close()
        await pause(1)
        let settingsMB = footprintMB()

        let intervals = result.frameIntervals.sorted()
        func percentile(_ p: Double) -> Double {
            intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * p))] * 1000
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let date = ISO8601DateFormatter().string(from: Date())
        let label = (value(after: "--label") ?? "").replacingOccurrences(of: ",", with: " ")
        // A generic name, so shared results don't reveal the hardware
        let screenName = "screen \(index + 1) (\(screen.maximumFramesPerSecond) Hz)"
        let line = [date, version, label, screenName,
                    "\(screen.maximumFramesPerSecond)",
                    f(launchMB), f(idle.cpu, 2), f(idle.wakeups), f(scroll.cpu, 2), f(scroll.wakeups),
                    f(Double(intervals.count + 1) / scroll.seconds), f(percentile(0.5), 2), f(percentile(0.95), 2),
                    f(Double(result.events) / scroll.seconds), f(lookupMs, 2), f(settingsMB)].joined(separator: ",")

        print(csvHeader)
        print(line)
        if let out = value(after: "--out") {
            let url = URL(fileURLWithPath: out)
            if !FileManager.default.fileExists(atPath: out) {
                try? (csvHeader + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }
        NSApp.terminate(nil)
    }

    // MARK: - Measuring

    private struct Usage {
        let cpu: Double      // percent of one core
        let wakeups: Double  // per second
        let seconds: Double  // wall time measured
    }

    private static func measure(_ body: () async -> Void) async -> Usage {
        let t0 = CACurrentMediaTime(), c0 = cpuSeconds(), w0 = wakeupCount()
        await body()
        let wall = CACurrentMediaTime() - t0
        return Usage(cpu: (cpuSeconds() - c0) / wall * 100, wakeups: Double(wakeupCount() - w0) / wall, seconds: wall)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func wakeupCount() -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    // MARK: - Helpers

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func f(_ value: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value)
    }
}
#endif
