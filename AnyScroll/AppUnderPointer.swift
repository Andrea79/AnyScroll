//
//  AppUnderPointer.swift
//  AnyScroll
//

import Cocoa

/// Finds the app that owns the window under a point, so auto-scroll can stay out
/// of the apps the user excluded. Safe to call from the click interceptor thread.
enum AppUnderPointer {
    /// Bundle identifier of the app whose window is under `point`, in display
    /// coordinates (origin at the top-left of the main display).
    static func bundleIdentifier(at point: CGPoint) -> String? {
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
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        return nil
    }
}
