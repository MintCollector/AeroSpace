public struct WorkspaceBackAndForthCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceBackAndForth,
        help: workspace_back_and_forth_help_generated,
        flags: [
            "--monitor": singleValueSubArgParser(\.monitor, "<monitor>", parseBackAndForthMonitor),
        ],
        posArgs: [],
    )

    /// The monitor to go back on. nil: the focused one
    public var monitor: BackAndForthMonitor? = nil
}

public enum BackAndForthMonitor: Equatable, Sendable {
    case focused
    case mouse
    case main
    case secondary
    case id(Int) // 1-based, as monitor-id in list-monitors
}

private func parseBackAndForthMonitor(_ raw: String) -> ResOrStr<BackAndForthMonitor> {
    switch raw {
        case "focused": return .success(.focused)
        case "mouse": return .success(.mouse)
        case "main": return .success(.main)
        case "secondary": return .success(.secondary)
        default:
            guard let id = Int(raw), id >= 1 else { return .failure("Possible values: (<monitor-id>|focused|mouse|main|secondary)") }
            return .success(.id(id))
    }
}
