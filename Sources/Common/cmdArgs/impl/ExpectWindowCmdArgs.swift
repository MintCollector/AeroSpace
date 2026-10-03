public struct ExpectWindowCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .expectWindow,
        help: expect_window_help_generated,
        flags: [
            "--app-id": singleValueSubArgParser(\.appId, "<app-bundle-id>", Result.success),
            "--app-name-regex-substring": singleValueSubArgParser(\.appNameRegexSubstring, "<regex>", CaseInsensitiveRegex.new),
            "--window-title-regex-substring": singleValueSubArgParser(\.windowTitleRegexSubstring, "<regex>", CaseInsensitiveRegex.new),
            "--timeout": singleValueSubArgParser(\.timeoutSeconds, "<seconds>", parseUInt32),
            "--focus": trueBoolFlag(\.takeFocus),
        ],
        posArgs: [
            dashDashArg(mandatory: false),
            ArgParser(\.commands, consumeAllStrPosArgs),
        ],
        conflictingOptions: [],
    )

    public var appId: String? = nil
    public var appNameRegexSubstring: CaseInsensitiveRegex? = nil
    public var windowTitleRegexSubstring: CaseInsensitiveRegex? = nil
    public var timeoutSeconds: UInt32? = nil
    public var takeFocus: Bool = false
    public var commands: [String] = []
}

public func parseExpectWindowCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ExpectWindowCmdArgs> {
    parseSpecificCmdArgs(ExpectWindowCmdArgs(rawArgs: args), args)
        .filter("At least one of --app-id, --app-name-regex-substring, --window-title-regex-substring is required") {
            $0.appId != nil || $0.appNameRegexSubstring != nil || $0.windowTitleRegexSubstring != nil
        }
}

private func consumeAllStrPosArgs(i: PosArgParserInput) -> ParsedCliArgs<[String]> {
    let args = i.args.slice(i.index...).orDie().toArray()
    return .succ(args, advanceBy: args.count)
}
