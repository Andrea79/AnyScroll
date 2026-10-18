//
//  AppUnderPointer.swift
//  AnyScroll
//

import Cocoa

/// Finds the window under a point and the app that owns it, for excluded apps,
/// per-app directions and keeping auto-scroll on the window it started in.
/// Safe to call from the click interceptor thread.
enum AppUnderPointer {
    struct Window {
        let bundleIdentifier: String?
        /// In display coordinates (origin at the top-left of the main display).
        let bounds: CGRect
    }

    /// The topmost normal app window under `point`, in display coordinates.
    static func window(at point: CGPoint) -> Window? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = getpid()
        // The list is ordered front to back; layer 0 holds normal app windows
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.contains(point) else { continue }
            return Window(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                          bounds: bounds)
        }
        return nil
    }

    /// Bundle identifier of the app whose window is under `point`, in display coordinates.
    static func bundleIdentifier(at point: CGPoint) -> String? {
        window(at: point)?.bundleIdentifier
    }
}
