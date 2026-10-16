//
//  DebugLog.swift
//  AnyScroll
//
//  Diagnostics for the Dev build only (compiled with -D DEBUG_LOG): appends to
//  ~/Library/Logs/AnyScroll Dev.log. In the release build write() is a no-op.
//

import Foundation

enum DebugLog {
    #if DEBUG_LOG
    private static let queue = DispatchQueue(label: "AnyScroll debug log")
    private static let start = ProcessInfo.processInfo.systemUptime
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AnyScroll Dev.log")

    static func write(_ message: @autoclosure () -> String) {
        let line = String(format: "%8.3f ", ProcessInfo.processInfo.systemUptime - start) + message() + "\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
    #else
    static func write(_ message: @autoclosure () -> String) {}
    #endif
}
