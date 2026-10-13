public struct SplitMonitorsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .splitMonitors,
        help: split_monitors_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
        ],
        posArgs: [newMandatoryPosArgParser(\.targetState, parseState, placeholder: SplitMonitorsCmdArgs.State.unionLiteral)],
    )
    public var targetState: Lateinit<State> = .uninitialized
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], targetState: State) {
        self.commonState = .init(rawArgs.slice)
        self.targetState = .initialized(targetState)
    }

    public enum State: String, CaseIterable, Sendable {
        case on, off, toggle
    }
}

func parseSplitMonitorsCmdArgs(_ args: StrArrSlice) -> ParsedCmd<SplitMonitorsCmdArgs> {
    parseSpecificCmdArgs(SplitMonitorsCmdArgs(rawArgs: args), args)
        .filterNot("--fail-if-noop is incompatible with 'toggle' argument") { $0.targetState.val == .toggle && $0.failIfNoop }
}

private func parseState(i: PosArgParserInput) -> ParsedCliArgs<SplitMonitorsCmdArgs.State> {
    .init(parseEnum(i.arg, SplitMonitorsCmdArgs.State.self), advanceBy: 1)
}
