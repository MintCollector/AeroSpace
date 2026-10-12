import AppKit
import Common

struct WorkspaceBackAndForthCommand: Command {
    let args: WorkspaceBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let monitor = resolveMonitor(env, io) else { return .fail }
        trackVisibleWorkspaces() // A switch made earlier in this command sequence counts too
        guard let workspace = monitor.backAndForthWorkspace else {
            return .fail(io.err("No workspace to go back to on monitor '\(monitor.name)'"))
        }
        dissolveViewToggles(workspace: focus.workspace)
        dissolveViewToggles(workspace: monitor.activeWorkspace)
        _ = monitor.setActiveWorkspace(workspace) // Here even if it has opened on another monitor since
        return .from(bool: workspace.focusWorkspace())
    }

    @MainActor private func resolveMonitor(_ env: CmdEnv, _ io: CmdIo) -> MonitorInfo? {
        let sortedMonitors = sortedMonitorInfos
        switch args.monitor ?? .focused {
            case .focused:
                return args.resolveTargetOrReportError(env, io)?.workspace.workspaceMonitor
            case .mouse:
                return mouseLocation.monitorApproximation
            case .main:
                return mainMonitorInfo
            case .secondary:
                guard let monitor = MonitorDescription.secondary.resolveMonitor(sortedMonitors: sortedMonitors) else {
                    io.err("There is no secondary monitor: it takes exactly two monitors")
                    return nil
                }
                return monitor
            case .id(let id):
                guard let monitor = sortedMonitors.getOrNil(atIndex: id - 1) else {
                    io.err("Invalid monitor ID: \(id)")
                    return nil
                }
                return monitor
        }
    }
}
