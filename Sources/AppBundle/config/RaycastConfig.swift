import AppKit
import TOMLDecoder

enum RaycastDefaultBehavior: String {
    case move, focus
}

struct RaycastConfig {
    var defaultBehavior: RaycastDefaultBehavior = .move
    var extensionApps: Set<String> = []
}

@MainActor var raycastConfig = RaycastConfig()

@MainActor
func loadRaycastConfig() {
    let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
    let url = xdgConfigHome.appending(path: "aerospace").appending(path: "raycast.toml")

    guard let content = try? String(contentsOf: url, encoding: .utf8),
          let table = try? TOMLTable(source: content) else {
        raycastConfig = RaycastConfig()
        return
    }

    var cfg = RaycastConfig()
    if let behavior = try? table.string(forKey: "default-behavior"), let b = RaycastDefaultBehavior(rawValue: behavior) {
        cfg.defaultBehavior = b
    }
    if let apps = try? table.array(forKey: "extension-apps") {
        var set = Set<String>()
        for i in 0..<apps.count {
            if let s = try? apps.string(atIndex: i) {
                set.insert(s)
            }
        }
        cfg.extensionApps = set
    }
    raycastConfig = cfg
}
