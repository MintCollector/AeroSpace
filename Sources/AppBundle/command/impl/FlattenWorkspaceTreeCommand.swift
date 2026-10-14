import AppKit
import Common

struct FlattenWorkspaceTreeCommand: Command {
    let args: FlattenWorkspaceTreeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        // workspace-sections: each section flattens on its own
        let containers = workspace.sections == nil ? [workspace.rootTilingContainer] : workspace.sectionContainers
        for container in containers {
            for window in container.allLeafWindowsRecursive {
                window.bind(to: container, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            }
        }
        workspace.normalizeContainers()
        return .succ
    }
}
