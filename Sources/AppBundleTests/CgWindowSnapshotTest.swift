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

}
