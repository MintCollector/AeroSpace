import AppKit
import Common

struct ListTreeCommand: Command {
    let args: ListTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    // Field sets the helper's tree DTOs expect. Keys come from each FormatVar.rawValue.
    // Window app-* vars resolve against the window's app via expandFormatVar's (.window, .app) bridge.
    static let windowVars: [FormatVar] = [
        .window(.windowId), .window(.windowTitle), .window(.windowIsFullscreen), .window(.windowLayout),
        .window(.windowX), .window(.windowY), .window(.windowWidth), .window(.windowHeight),
        .app(.appName), .app(.appBundleId), .app(.appPid), .app(.appExecPath), .app(.appBundlePath),
    ]
    static let workspaceVars: [FormatVar] = [
        .workspace(.workspaceName), .workspace(.workspaceFocused),
        .workspace(.workspaceVisible), .workspace(.workspaceRootContainerLayout),
    ]
    static let monitorVars: [FormatVar] = [
        .monitor(.monitorId_oneBased), .monitor(.monitorAppKitNsScreenScreensId),
        .monitor(.monitorName), .monitor(.monitorIsMain), .monitor(.monitorWidth), .monitor(.monitorHeight),
    ]

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> BinaryExitCode {
        // Resolve a node's fields through the shared formatter, keyed by FormatVar.rawValue.
        func fields(_ obj: AeroObj, _ vars: [FormatVar]) -> Result<[String: Primitive], String> {
            var dict: [String: Primitive] = [:]
            for v in vars {
                switch v.expandFormatVar(obj: obj) {
                    case .success(let p): dict[v.rawValue] = p
                    case .failure(let e): return .failure(e)
                }
            }
            return .success(dict)
        }

        // One WindowServer read for the whole tree: title + bounds for every window, joined by id
        // in the snapshot-fed resolver below. Replaces the per-window AX title/rect calls that
        // stalled the serialized MainActor.
        let snap = readCgWindowSnapshot()

        var monitorNodes: [JsonTreeNode] = []
        for monitor in sortedMonitors {
            let monitorPoint = monitor.rect.topLeftCorner
            let monitorWorkspaces = Workspace.all.filter { $0.workspaceMonitor.rect.topLeftCorner == monitorPoint }

            var workspaceNodes: [JsonTreeNode] = []
            for workspace in monitorWorkspaces {
                // Preserve allLeafWindowsRecursive order — the helper derives window-tree-index from it.
                var windowNodes: [JsonTreeNode] = []
                for window in workspace.allLeafWindowsRecursive where window.isBound {
                    let resolved = try await WindowWithPrefetchedTitle.resolveWindow(window, fromSnapshot: snap)
                    switch fields(.window(resolved), Self.windowVars) {
                        case .success(let f): windowNodes.append(JsonTreeNode(fields: f, childrenKey: nil, children: nil))
                        case .failure(let e): return .fail(io.err(e))
                    }
                }
                switch fields(.workspace(workspace), Self.workspaceVars) {
                    case .success(let f): workspaceNodes.append(JsonTreeNode(fields: f, childrenKey: "windows", children: windowNodes))
                    case .failure(let e): return .fail(io.err(e))
                }
            }

            switch fields(.monitor(monitor), Self.monitorVars) {
                case .success(let f): monitorNodes.append(JsonTreeNode(fields: f, childrenKey: "workspaces", children: workspaceNodes))
                case .failure(let e): return .fail(io.err(e))
            }
        }

        let root = JsonTreeRoot(focusedWindowId: focus.windowOrNil?.windowId, monitors: monitorNodes)
        guard let json = JSONEncoder.aeroSpaceDefault.encodeToString(root) else {
            return .fail(io.err("Failed to encode tree to JSON"))
        }
        return .succ(io.out(json))
    }
}

/// Root of `list-tree`: the focused window's id (null when nothing is focused) plus the monitor
/// array. aero-helper reads `focused-window-id` here instead of a separate `list-windows --focused`
/// query, so the hot poll is a single request.
private struct JsonTreeRoot: Encodable {
    let focusedWindowId: UInt32?
    let monitors: [JsonTreeNode]

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        try c.encode(focusedWindowId.map { Int64($0) }, forKey: DynKey("focused-window-id"))
        try c.encode(monitors, forKey: DynKey("monitors"))
    }
}

private struct DynKey: CodingKey {
    let stringValue: String
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// One JSON object: the resolved `FormatVar` fields, plus an optional nested child array under
/// `childrenKey` ("workspaces"/"windows"). Lets list-tree reuse the shared field resolution while
/// keeping the bespoke monitor->workspace->window nesting the flat formatter can't express.
private struct JsonTreeNode: Encodable {
    let fields: [String: Primitive]
    let childrenKey: String?
    let children: [JsonTreeNode]?

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        for (k, v) in fields { try c.encode(v, forKey: DynKey(k)) }
        if let childrenKey, let children { try c.encode(children, forKey: DynKey(childrenKey)) }
    }
}
