@testable import AppBundle
import Common
import XCTest

@MainActor
final class ActiveWorkspaceTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAMonitorThatIsGoneShowsTheWorkspaceInItsPlace() {
        // A command captured the monitor, then awaited while it was unplugged. This used to recurse forever
        assertEquals(GoneMonitor().activeWorkspace, mainMonitorInfo.activeWorkspace)
    }
}

/// A monitor right of the test monitor, which doesn't exist (any more)
private struct GoneMonitor: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Gone"
    let rect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let visibleRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
    let isMain = false
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
}
