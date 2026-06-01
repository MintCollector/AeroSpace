import AppKit
import Common

struct WorkspaceBackAndForthCommand: Command {
    let args: WorkspaceBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        dissolveViewToggles(workspace: focus.workspace)
        return .from(bool: prevFocusedWorkspace?.focusWorkspace() != nil)
    }
}
