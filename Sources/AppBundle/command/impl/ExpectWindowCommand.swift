import Common
import Foundation

struct ExpectWindowCommand: Command {
    let args: ExpectWindowCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        var shells: [Shell<any Command>] = []
        for raw in args.commands {
            switch parseCommand(raw, allowExecAndForget: true, allowEval: false) {
                case .cmd(let shell): shells.append(shell)
                case .help: return .fail(io.err("--help is not supported inside expect-window commands"))
                case .failure(let f): return .fail(io.err("Can't parse expect-window command \(raw.singleQuoted): \(f.msg)"))
            }
        }
        let matcher = LegacyWindowDetectedCallbackMatcher(
            appId: args.appId,
            appNameRegexSubstring: args.appNameRegexSubstring,
            windowTitleRegexSubstring: args.windowTitleRegexSubstring,
        )
        armWindowExpectation(
            matcher: matcher,
            commands: .newCompound(shells, Shell<any Command>.seq),
            timeout: TimeInterval(args.timeoutSeconds ?? 10),
            takeFocus: args.takeFocus,
        )
        return .succ
    }
}
