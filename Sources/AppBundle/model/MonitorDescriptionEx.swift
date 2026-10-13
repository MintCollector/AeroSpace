import Common

extension MonitorDescription {
    /// `sortedMonitors`: left to right, `monitorInfos` for pins and commands, `screenInfos` for gaps
    @MainActor func resolveMonitor(sortedMonitors: [MonitorInfo]) -> MonitorInfo? {
        switch self {
            case .sequenceNumber(let number): sortedMonitors.getOrNil(atIndex: number - 1)
            case .main: sortedMonitors.first(where: \.isMain)
            case .pattern(let regex): sortedMonitors.first { $0.name.contains(caseInsensitiveRegex: regex) }
            case .secondary: sortedMonitors.takeIf { $0.count == 2 }?.first { !$0.isMain }
        }
    }
}
