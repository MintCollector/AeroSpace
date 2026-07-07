#!/usr/bin/env swift
// Compares AeroSpace's known windows against CGWindowListCopyWindowInfo to verify
// that CGWindowList can replace the AX-based alive check.
//
// Usage:
//   swift script/test-cgwindowlist-alive.swift          # one-shot comparison
//   swift script/test-cgwindowlist-alive.swift --watch   # poll every second (quit an app to observe)

import CoreGraphics
import Foundation

// MARK: - CGWindowList snapshot

struct CgWindow {
    let id: UInt32
    let pid: Int32
    let ownerName: String
    let name: String?
    let layer: Int
    let isOnScreen: Bool
    let bounds: CGRect?
}

func readCgWindows() -> [UInt32: CgWindow] {
    let options = CGWindowListOption([.excludeDesktopElements])
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [NSDictionary] else { return [:] }
    var result: [UInt32: CgWindow] = [:]
    for dict in cfArray {
        guard let num = dict[kCGWindowNumber] as? NSNumber else { continue }
        let id = num.uint32Value
        let pid = (dict[kCGWindowOwnerPID] as? NSNumber)?.int32Value ?? 0
        let ownerName = dict[kCGWindowOwnerName] as? String ?? "?"
        let name = dict[kCGWindowName] as? String
        let layer = (dict[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
        let isOnScreen = (dict[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
        var bounds: CGRect? = nil
        if let b = dict[kCGWindowBounds] as? NSDictionary,
           let x = (b["X"] as? NSNumber)?.doubleValue,
           let y = (b["Y"] as? NSNumber)?.doubleValue,
           let w = (b["Width"] as? NSNumber)?.doubleValue,
           let h = (b["Height"] as? NSNumber)?.doubleValue
        {
            bounds = CGRect(x: x, y: y, width: w, height: h)
        }
        result[id] = CgWindow(id: id, pid: pid, ownerName: ownerName, name: name,
                              layer: layer, isOnScreen: isOnScreen, bounds: bounds)
    }
    return result
}

// MARK: - AeroSpace window list

struct AeroWindow {
    let id: UInt32
    let appName: String
    let workspace: String
    let title: String
}

func readAeroWindows() -> [UInt32: AeroWindow] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["aerospace", "list-windows", "--all",
                      "--format", "%{window-id}|%{app-name}|%{workspace}|%{window-title}"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [:] }
    var result: [UInt32: AeroWindow] = [:]
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count >= 3, let id = UInt32(parts[0]) else { continue }
        result[id] = AeroWindow(id: id, appName: parts[1], workspace: parts[2],
                                title: parts.count > 3 ? parts[3] : "")
    }
    return result
}

// MARK: - Comparison

func compare() {
    let cgWindows = readCgWindows()
    let aeroWindows = readAeroWindows()

    let aeroIds = Set(aeroWindows.keys)
    let cgIds = Set(cgWindows.keys)

    let matched = aeroIds.intersection(cgIds)
    let missingFromCg = aeroIds.subtracting(cgIds)  // AeroSpace knows it, CGWindowList doesn't
    let extraInCg = cgIds.subtracting(aeroIds)       // CGWindowList has it, AeroSpace doesn't

    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] AeroSpace: \(aeroIds.count) windows | CGWindowList: \(cgIds.count) entries | Matched: \(matched.count)")

    if !missingFromCg.isEmpty {
        print("  ⚠️  IN AEROSPACE BUT NOT IN CGWindowList (\(missingFromCg.count)):")
        for id in missingFromCg.sorted() {
            let aw = aeroWindows[id]!
            print("     window \(id): \(aw.appName) [\(aw.workspace)] \"\(aw.title)\"")
        }
    }

    if matched.count == aeroIds.count && !aeroIds.isEmpty {
        print("  ✅ All AeroSpace windows found in CGWindowList")
    }

    // Show details for matched windows
    if CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v") {
        print("  Matched windows:")
        for id in matched.sorted() {
            let aw = aeroWindows[id]!
            let cg = cgWindows[id]!
            let onScreen = cg.isOnScreen ? "on-screen" : "OFF-SCREEN"
            print("     \(id): \(aw.appName) [\(aw.workspace)] layer=\(cg.layer) \(onScreen)")
        }
    }

    // Show stats about unmanaged CGWindowList entries (just for context)
    if CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v") {
        let layer0Extra = extraInCg.filter { cgWindows[$0]?.layer == 0 }
        if !layer0Extra.isEmpty {
            print("  CGWindowList layer-0 windows NOT in AeroSpace (\(layer0Extra.count)):")
            for id in layer0Extra.sorted() {
                let cg = cgWindows[id]!
                let onScreen = cg.isOnScreen ? "on-screen" : "OFF-SCREEN"
                print("     \(id): \(cg.ownerName) \(onScreen) \"\(cg.name ?? "")\"")
            }
        }
    }
}

// MARK: - Main

if CommandLine.arguments.contains("--watch") || CommandLine.arguments.contains("-w") {
    print("Watching... (quit an app or minimize a window to see changes, Ctrl-C to stop)")
    print("---")
    var prevMissing: Set<UInt32> = []
    while true {
        let cgWindows = readCgWindows()
        let aeroWindows = readAeroWindows()
        let aeroIds = Set(aeroWindows.keys)
        let cgIds = Set(cgWindows.keys)
        let missingFromCg = aeroIds.subtracting(cgIds)

        if missingFromCg != prevMissing || missingFromCg.isEmpty == false {
            compare()
            print("---")
            prevMissing = missingFromCg
        } else {
            // Compact one-liner when nothing interesting
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] ✅ \(aeroIds.count) aero / \(cgIds.count) cg — all matched", terminator: "\r")
            fflush(stdout)
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
} else {
    compare()
}
