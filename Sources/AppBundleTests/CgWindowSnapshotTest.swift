@testable import AppBundle
import CoreGraphics
import XCTest

final class CgWindowSnapshotTest: XCTestCase {
    func testParseJoinsByWindowNumberAndReadsTitleAndBounds() {
        let withTitleAndBounds: [String: Any] = [
            kCGWindowNumber as String: 42,
            kCGWindowName as String: "kitty — zsh",
            kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": 300, "Height": 400],
        ]
        let bare: [String: Any] = [kCGWindowNumber as String: 7] // no name/bounds
        let dicts: [NSDictionary] = [withTitleAndBounds as NSDictionary, bare as NSDictionary]

        let snap = parseCgWindowSnapshot(dicts)

        assertEquals(snap[42]?.title, "kitty — zsh")
        assertEquals(snap[42]?.rect?.topLeftX, 100)
        assertEquals(snap[42]?.rect?.topLeftY, 200)
        assertEquals(snap[42]?.rect?.width, 300)
        assertEquals(snap[42]?.rect?.height, 400)

        // Window present but no title/bounds → entry exists with nil fields.
        assertTrue(snap[7] != nil)
        assertEquals(snap[7]?.title, nil)
        assertTrue(snap[7]?.rect == nil)

        // Absent window → no entry.
        assertTrue(snap[999] == nil)
    }

    func testParseSkipsDictsWithoutWindowNumber() {
        let noNumber: [String: Any] = [kCGWindowName as String: "ghost"]
        let snap = parseCgWindowSnapshot([noNumber as NSDictionary])
        assertEquals(snap.count, 0)
    }

    func testANormalWindowUnderTheMouseIsntTheDesktop() {
        func window(layer: Int, x: Int, y: Int, width: Int, height: Int) -> NSDictionary {
            [kCGWindowLayer as String: layer, kCGWindowBounds as String: ["X": x, "Y": y, "Width": width, "Height": height]] as NSDictionary
        }
        let dialog = window(layer: 0, x: 1300, y: 300, width: 400, height: 200)
        let panel = window(layer: 3, x: 0, y: 0, width: 1920, height: 1080) // above everything, e.g. a helper's overlay
        assertTrue(isNormalWindow(at: CGPoint(x: 1500, y: 400), [panel, dialog]))
        assertFalse(isNormalWindow(at: CGPoint(x: 1800, y: 900), [panel, dialog]))
        assertFalse(isNormalWindow(at: CGPoint(x: 1500, y: 400), []))
    }
}
