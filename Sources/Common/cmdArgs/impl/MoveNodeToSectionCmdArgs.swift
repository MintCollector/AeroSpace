public struct MoveNodeToSectionCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .moveNodeToSection,
        help: move_node_to_section_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [newMandatoryPosArgParser(\.section, parseSectionName, placeholder: "<section>")],
    )
    public var section: Lateinit<String> = .uninitialized
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], section: String) {
        self.commonState = .init(rawArgs.slice)
        self.section = .initialized(section)
    }
}

func parseMoveNodeToSectionCmdArgs(_ args: StrArrSlice) -> ParsedCmd<MoveNodeToSectionCmdArgs> {
    parseSpecificCmdArgs(MoveNodeToSectionCmdArgs(rawArgs: args), args)
}

private func parseSectionName(i: PosArgParserInput) -> ParsedCliArgs<String> {
    .init(.success(i.arg), advanceBy: 1)
}
