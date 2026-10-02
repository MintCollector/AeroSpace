import Common

struct ExpectWindowCommand: Command {
    let args: ExpectWindowCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        .succ
    }
}
