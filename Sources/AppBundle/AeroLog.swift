import Foundation
import Common

private let logFile: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("AeroSpace.log").path
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let handle = FileHandle(forWritingAtPath: path)
    handle?.seekToEndOfFile()
    return handle
}()

private nonisolated(unsafe) let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    f.timeZone = .current
    return f
}()

func aeroLog(_ category: String, _ msg: String) {
    let ts = tsFormatter.string(from: Date())
    let event = refreshSessionEvent?.description ?? "-"
    let line = "[\(ts)] [\(category)] [\(event)] \(msg)\n"
    eprint("[\(category)] \(msg)")
    logFile?.seekToEndOfFile()
    if let data = line.data(using: .utf8) {
        logFile?.write(data)
    }
}
