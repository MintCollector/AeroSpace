import AppKit
import Common

struct ListTreeCommand: Command {
    let args: ListTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let focusedWorkspace = focus.workspace
        var monitorNodes: [MonitorNode] = []

        for monitor in sortedMonitors {
            let monitorPoint = monitor.rect.topLeftCorner
            let monitorWorkspaces = Workspace.all
                .filter { $0.workspaceMonitor.rect.topLeftCorner == monitorPoint }

            var workspaceNodes: [WorkspaceNode] = []
            for workspace in monitorWorkspaces {
                var windowNodes: [WindowNode] = []
                for window in workspace.allLeafWindowsRecursive {
                    guard window.isBound else { continue }
                    let title = try await window.title
                    let rect = try await window.getAxRect()
                    windowNodes.append(WindowNode(
                        window_id: window.windowId,
                        window_title: title,
                        window_is_fullscreen: window.isFullscreen,
                        window_layout: windowLayout(window),
                        window_x: rect.map { Int($0.topLeftX) } ?? 0,
                        window_y: rect.map { Int($0.topLeftY) } ?? 0,
                        window_width: rect.map { Int($0.width) } ?? 0,
                        window_height: rect.map { Int($0.height) } ?? 0,
                        app_name: window.app.name ?? "",
                        app_bundle_id: window.app.rawAppBundleId,
                        app_pid: window.app.pid,
                        app_exec_path: window.app.execPath,
                        app_bundle_path: window.app.bundlePath
                    ))
                }
                windowNodes.sort { ($0.app_name, $0.window_title) < ($1.app_name, $1.window_title) }

                workspaceNodes.append(WorkspaceNode(
                    workspace: workspace.name,
                    workspace_is_focused: workspace == focusedWorkspace,
                    workspace_is_visible: workspace.isVisible,
                    workspace_root_container_layout: layoutString(workspace.rootTilingContainer),
                    windows: windowNodes
                ))
            }

            monitorNodes.append(MonitorNode(
                monitor_id: monitor.monitorId_oneBased ?? 0,
                monitor_appkit_nsscreen_screens_id: monitor.monitorAppKitNsScreenScreensId,
                monitor_name: monitor.name,
                monitor_is_main: monitor.isMain,
                monitor_width: Int(monitor.width),
                monitor_height: Int(monitor.height),
                workspaces: workspaceNodes
            ))
        }

        guard let json = JSONEncoder.aeroSpaceDefault.encodeToString(monitorNodes) else {
            return io.err("Failed to encode tree to JSON")
        }
        return io.out(json)
    }
}

private func layoutString(_ tc: TilingContainer) -> String {
    switch (tc.layout, tc.orientation) {
        case (.tiles, .h): LayoutCmdArgs.LayoutDescription.h_tiles.rawValue
        case (.tiles, .v): LayoutCmdArgs.LayoutDescription.v_tiles.rawValue
        case (.accordion, .h): LayoutCmdArgs.LayoutDescription.h_accordion.rawValue
        case (.accordion, .v): LayoutCmdArgs.LayoutDescription.v_accordion.rawValue
    }
}

private func windowLayout(_ w: Window) -> String {
    guard let parent = w.parent else { return "NULL-PARENT" }
    return switch getChildParentRelation(child: w, parent: parent) {
        case .tiling(let tc): layoutString(tc)
        case .floatingWindow: LayoutCmdArgs.LayoutDescription.floating.rawValue
        case .macosNativeFullscreenWindow: "macos_native_fullscreen"
        case .macosNativeHiddenAppWindow: "macos_native_window_of_hidden_app"
        case .macosNativeMinimizedWindow: "macos_native_minimized"
        case .macosPopupWindow: "NULL-WINDOW-LAYOUT"
        case .rootTilingContainer: "NULL-WINDOW-LAYOUT"
        case .shimContainerRelation: "NULL-WINDOW-LAYOUT"
    }
}

private struct MonitorNode: Encodable {
    let monitor_id: Int
    let monitor_appkit_nsscreen_screens_id: Int
    let monitor_name: String
    let monitor_is_main: Bool
    let monitor_width: Int
    let monitor_height: Int
    let workspaces: [WorkspaceNode]

    enum CodingKeys: String, CodingKey {
        case monitor_id = "monitor-id"
        case monitor_appkit_nsscreen_screens_id = "monitor-appkit-nsscreen-screens-id"
        case monitor_name = "monitor-name"
        case monitor_is_main = "monitor-is-main"
        case monitor_width = "monitor-width"
        case monitor_height = "monitor-height"
        case workspaces
    }
}

private struct WorkspaceNode: Encodable {
    let workspace: String
    let workspace_is_focused: Bool
    let workspace_is_visible: Bool
    let workspace_root_container_layout: String
    let windows: [WindowNode]

    enum CodingKeys: String, CodingKey {
        case workspace
        case workspace_is_focused = "workspace-is-focused"
        case workspace_is_visible = "workspace-is-visible"
        case workspace_root_container_layout = "workspace-root-container-layout"
        case windows
    }
}

private struct WindowNode: Encodable {
    let window_id: UInt32
    let window_title: String
    let window_is_fullscreen: Bool
    let window_layout: String
    let window_x: Int
    let window_y: Int
    let window_width: Int
    let window_height: Int
    let app_name: String
    let app_bundle_id: String?
    let app_pid: Int32
    let app_exec_path: String?
    let app_bundle_path: String?

    enum CodingKeys: String, CodingKey {
        case window_id = "window-id"
        case window_title = "window-title"
        case window_is_fullscreen = "window-is-fullscreen"
        case window_layout = "window-layout"
        case window_x = "window-x"
        case window_y = "window-y"
        case window_width = "window-width"
        case window_height = "window-height"
        case app_name = "app-name"
        case app_bundle_id = "app-bundle-id"
        case app_pid = "app-pid"
        case app_exec_path = "app-exec-path"
        case app_bundle_path = "app-bundle-path"
    }
}
