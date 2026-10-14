@testable import AppBundle
import XCTest

final class TerminationTest: XCTestCase {
    func testQuitCentersWindowsOnTheirMonitor() {
        // The laptop below the ultrawide: centering used to ignore the monitor's origin
        let laptop = Rect(topLeftX: 1764, topLeftY: 1440, width: 1800, height: 1169)
        assertEquals(terminationTopLeft(size: CGSize(width: 800, height: 600), visibleRect: laptop), CGPoint(x: 2264, y: 1724.5))
    }
}
