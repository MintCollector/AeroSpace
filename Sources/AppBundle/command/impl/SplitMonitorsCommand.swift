import AppKit
import Common

struct SplitMonitorsCommand: Command {
    let args: SplitMonitorsCmdArgs
    /// The closed windows cache remembers monitors by corner, which the split changes
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let newState: Bool = switch args.targetState.val {
            case .on: true
            case .off: false
            case .toggle: !splitMonitorsEnabled
        }
        if newState == splitMonitorsEnabled {
            switch args.failIfNoop {
                case true: return .fail
                case false:
                    let msg = newState
                        ? "Already split. Tip: use --fail-if-noop to exit with non-zero code"
                        : "Already not split. Tip: use --fail-if-noop to exit with non-zero code"
                    return .succ(io.err(msg))
            }
        }
        changeMonitorSplit { splitMonitorsEnabled = newState }
        return .succ
    }
}
