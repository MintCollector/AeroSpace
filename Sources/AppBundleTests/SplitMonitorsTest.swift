@testable import AppBundle
import Common
import XCTest

@MainActor
final class SplitMonitorsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testColumnsOfAScreen() {
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen())
        assertEquals(columns.map(\.rect.topLeftX), [0, 1280, 3840])
        assertEquals(columns.map(\.rect.width), [1280, 2560, 1280])
        assertEquals(columns.map(\.rect.height), [1440, 1440, 1440])
        assertEquals(columns.map(\.name), ["C49RG9x 1", "C49RG9x 2", "C49RG9x 3"])
        assertEquals(columns.map(\.isMain), [false, true, false])
        assertEquals(columns.map(\.monitorAppKitNsScreenScreensId), [1, 1, 1])
        assertEquals(columns.map(\.screen.rect.width), [5120, 5120, 5120])
    }

    func testColumnsKeepTheScreensVisibleArea() {
        // The menu bar on top and the Dock on the right of the screen
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen())
        assertEquals(columns.map(\.visibleRect.minX), [0, 1280, 3840])
        assertEquals(columns.map(\.visibleRect.maxX), [1280, 3840, 5057])
        assertEquals(columns.map(\.visibleRect.minY), [30, 30, 30])
        assertEquals(columns.map(\.visibleRect.height), [1410, 1410, 1410])
    }

    func testOnlyTheMainScreenHasAMainColumn() {
        let columns = splitMonitorRule("C49RG9x").columnMonitors(of: UltrawideScreen(isMain: false))
        assertEquals(columns.map(\.isMain), [false, false, false])
        assertEquals(columns.map(\.isPrimaryColumn), [false, true, false])
    }

    func testMonitorsAreTheColumnsOfSplitScreens() {
        assertEquals(monitorInfos.map(\.name), ["Test Monitor"])
        splitTestMonitor()
        assertEquals(monitorInfos.map(\.name), ["Test Monitor 1", "Test Monitor 2", "Test Monitor 3"])
        assertEquals(mainMonitorInfo.name, "Test Monitor 2")
        assertEquals(screenInfos.map(\.name), ["Test Monitor"])
        assertEquals(mainScreenInfo.width, 1920) // coordinates still convert through the whole screen

        splitMonitorsEnabled = false
        assertEquals(monitorInfos.map(\.name), ["Test Monitor"])
        assertEquals(mainMonitorInfo.name, "Test Monitor")
    }
}

/// James's C49RG9x: menu bar on top, Dock on the right
private struct UltrawideScreen: MonitorInfo {
    var isMain = true
    let rect = Rect(topLeftX: 0, topLeftY: 0, width: 5120, height: 1440)
    let visibleRect = Rect(topLeftX: 0, topLeftY: 30, width: 5057, height: 1410)
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let monitorAppKitNsScreenScreensId = 1
    let name = "C49RG9x"
}
