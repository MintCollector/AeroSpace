@testable import AppBundle
import Common

@MainActor
func splitMonitorRule(_ pattern: String, columns: [Int] = [1, 2, 1], main: Int = 2) -> SplitMonitorRule {
    SplitMonitorRule(pattern: try! CaseInsensitiveRegex.new(pattern).get(), columns: columns, main: main)
}

/// The 1920x1080 test monitor as columns 480 | 960 | 480 with the middle one main, like James's 1280 | 2560 | 1280
@MainActor
func splitTestMonitor(columns: [Int] = [1, 2, 1], main: Int = 2) {
    config.splitMonitors = [splitMonitorRule("test monitor", columns: columns, main: main)]
    gcMonitors()
}

/// The test monitor's three columns, left to right
@MainActor
var testColumns: (left: MonitorInfo, center: MonitorInfo, right: MonitorInfo) {
    let columns = sortedMonitorInfos
    check(columns.count == 3, "\(columns.map(\.name))")
    return (columns[0], columns[1], columns[2])
}
