import Common

/// `[split-monitors.<pattern>]`: the screens whose name matches `pattern` show as side-by-side columns,
/// each of them a monitor of its own
struct SplitMonitorRule: ConvenienceMutable, Equatable, Sendable {
    /// Case insensitive regex substring of the screen's name, like the monitor patterns of
    /// workspace-to-monitor-force-assignment
    var pattern: CaseInsensitiveRegex
    /// Relative widths, left to right
    var columns: [Int] = []
    /// 1-based. The screen's primary column: it's the main monitor when the screen is the main one, and the column
    /// the screen's workspace moves to when the split turns on
    var main: Int = 1
}

private let splitMonitorRuleParser: [String: any ParserProtocol<SplitMonitorRule>] = [
    "columns": Parser(\.columns, parseColumnWidths),
    "main": Parser(\.main, parseInt),
]

func parseSplitMonitors(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [SplitMonitorRule] {
    guard let table = raw.asDictOrNil else {
        c.errors.append(expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace))
        return []
    }
    var result: [SplitMonitorRule] = []
    for (key, rawRule) in table {
        let ruleBacktrace = backtrace + .key(key)
        let pattern: CaseInsensitiveRegex
        switch parseMonitorDescription(key) {
            case .success(.pattern(let regex)): pattern = regex
            case .success:
                // 'main' would split the laptop whenever the ultrawide is unplugged
                c.errors.append(.init(ruleBacktrace, "Expected a monitor name pattern. 'main', 'secondary' and monitor numbers would split whichever monitor has that role"))
                continue
            case .failure(let msg):
                c.errors.append(.init(ruleBacktrace, msg))
                continue
        }
        let errorsBefore = c.errors.count
        let rule = parseTable(rawRule, SplitMonitorRule(pattern: pattern), splitMonitorRuleParser, ruleBacktrace, &c)
        if c.errors.count > errorsBefore { continue }
        if rule.columns.count < 2 {
            c.errors.append(.init(ruleBacktrace + .key("columns"), "Expected at least two column widths"))
        } else if !(1 ... rule.columns.count).contains(rule.main) {
            c.errors.append(.init(ruleBacktrace + .key("main"), "Expected a column number from 1 to \(rule.columns.count)"))
        } else {
            result.append(rule)
        }
    }
    return result
}

private func parseColumnWidths(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[Int]> {
    parseTomlArray(raw, backtrace).flatMap { array in
        array.enumerated().mapAllOrFailure { index, value in
            parseInt(value, backtrace + .index(index))
                .filter(.init(backtrace + .index(index), "Expected a positive width")) { $0 > 0 }
        }
    }
}
