import AppKit
import Common

private struct MonitorInfoImpl {
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool
}

extension MonitorInfoImpl: MonitorInfo {
    var height: CGFloat { rect.height }
    var width: CGFloat { rect.width }
}

/// Use it instead of NSScreen because it can be mocked in tests
protocol MonitorInfo: AeroAny {
    /// The index in NSScreen.screens array. 1-based index
    var monitorAppKitNsScreenScreensId: Int { get }
    var name: String { get }
    var rect: Rect { get }
    var visibleRect: Rect { get }
    var width: CGFloat { get }
    var height: CGFloat { get }
    var isMain: Bool { get }
    /// The physical screen the monitor is on: the whole screen for a column of a split screen (split-monitors),
    /// otherwise the monitor itself
    var screen: MonitorInfo { get }
}

extension MonitorInfo {
    var screen: MonitorInfo { self }
}

final class LazyMonitorInfo: MonitorInfo {
    private let nsScreen: NSScreen
    let monitorAppKitNsScreenScreensId: Int
    let name: String
    let width: CGFloat
    let height: CGFloat
    let isMain: Bool
    private var _rect: Rect?
    private var _visibleRect: Rect?

    init(monitorAppKitNsScreenScreensId: Int, isMain: Bool, _ screen: NSScreen) {
        self.monitorAppKitNsScreenScreensId = monitorAppKitNsScreenScreensId
        self.name = screen.localizedName
        self.width = screen.frame.width // Don't call rect because it would cause recursion during mainMonitor init
        self.height = screen.frame.height // Don't call rect because it would cause recursion during mainMonitor init
        self.nsScreen = screen
        self.isMain = isMain
    }

    var rect: Rect {
        _rect ?? nsScreen.rect.also { _rect = $0 }
    }

    var visibleRect: Rect {
        _visibleRect ?? nsScreen.visibleRect.also { _visibleRect = $0 }
    }
}

// Note to myself: Don't use NSScreen.main, it's garbage
// 1. The name is misleading, it's supposed to be called "focusedScreen"
// 2. It's inaccurate because NSScreen.main doesn't work correctly from NSWorkspace.didActivateApplicationNotification &
//    kAXFocusedWindowChangedNotification callbacks.
extension NSScreen {
    fileprivate func toMonitorInfo(monitorAppKitNsScreenScreensId: Int) -> MonitorInfo {
        MonitorInfoImpl(
            monitorAppKitNsScreenScreensId: monitorAppKitNsScreenScreensId,
            name: localizedName,
            rect: rect,
            visibleRect: visibleRect,
            isMain: isMainScreen,
        )
    }

    fileprivate var isMainScreen: Bool {
        frame.minX == 0 && frame.minY == 0
    }

    /// The property is a replacement for Apple's crazy ``frame``
    ///
    /// - For ``MacWindow.topLeftCorner``, (0, 0) is main screen top left corner, and positive y-axis goes down.
    /// - For ``frame``, (0, 0) is main screen bottom left corner, and positive y-axis goes up (which is crazy).
    ///
    /// The property "normalizes" ``frame``
    fileprivate var rect: Rect { frame.monitorFrameNormalized() }

    /// Same as ``rect`` but for ``visibleFrame``
    fileprivate var visibleRect: Rect { visibleFrame.monitorFrameNormalized() }
}

private let testMonitorInfoRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
private let testMonitorInfo = MonitorInfoImpl(
    monitorAppKitNsScreenScreensId: 1,
    name: "Test Monitor",
    rect: testMonitorInfoRect,
    visibleRect: testMonitorInfoRect,
    isMain: true,
)

/// The physical main screen (at the origin, with the menu bar), never one of its columns. Coordinate conversions
/// use its height, so it must not depend on `monitorInfos`, whose rects are converted through it
var mainScreenInfo: MonitorInfo {
    if isUnitTest { return testMonitorInfo }
    let screens = NSScreen.screens
    // Fallback: If main screen can't be found (e.g., during display reconfiguration),
    // return screens.first or testMonitor to avoid crash
    let screen = screens.withIndex.singleOrNil(where: \.value.isMainScreen) ?? screens.first.map { (0, $0) }
    guard let screen else { return testMonitorInfo }
    return LazyMonitorInfo(monitorAppKitNsScreenScreensId: screen.index + 1, isMain: true, screen.value)
}

/// The physical screens, unsplit
var screenInfos: [MonitorInfo] {
    isUnitTest
        ? [testMonitorInfo]
        : NSScreen.screens.enumerated().map { $0.element.toMonitorInfo(monitorAppKitNsScreenScreensId: $0.offset + 1) }
}

/// The monitors workspaces show on: the screens, each split screen as its columns (split-monitors)
@MainActor var monitorInfos: [MonitorInfo] { splitScreens(screenInfos) }

/// The main screen, or its primary column when it's split
@MainActor var mainMonitorInfo: MonitorInfo {
    let monitors = monitorInfos
    return monitors.first(where: \.isMain) ?? monitors.first ?? mainScreenInfo
}

@MainActor var sortedMonitorInfos: [MonitorInfo] {
    monitorInfos.sortedBy([\.rect.minX, \.rect.minY])
}

var sortedScreenInfos: [MonitorInfo] {
    screenInfos.sortedBy([\.rect.minX, \.rect.minY])
}
