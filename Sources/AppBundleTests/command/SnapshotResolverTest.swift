@testable import AppBundle
import Common
import XCTest

final class SnapshotResolverTest: XCTestCase {
    @MainActor
    func testSnapshotTitleWinsOverAx() async throws {
        setUpWorkspacesForTests()
        let w = TestWindow.new(id: 11, parent: focus.workspace.rootTilingContainer)
        let snap: [UInt32: CgWindowInfo] = [11: CgWindowInfo(title: "real title", rect: nil)]
        let resolved = try await WindowWithPrefetchedTitle.resolveWindow(w, fromSnapshot: snap)
        assertEquals(resolved.title, "real title") // not the AX fallback "TestWindow(11)"
    }

    @MainActor
    func testMissingSnapshotTitleFallsBackToAx() async throws {
        setUpWorkspacesForTests()
        let w = TestWindow.new(id: 12, parent: focus.workspace.rootTilingContainer)
        let snap: [UInt32: CgWindowInfo] = [:] // window absent → AX fallback
        let resolved = try await WindowWithPrefetchedTitle.resolveWindow(w, fromSnapshot: snap)
        assertEquals(resolved.title, "TestWindow(12)") // TestWindow.title returns its description
    }

    @MainActor
    func testCachedLayoutRectWinsOverSnapshotRect() async throws {
        setUpWorkspacesForTests()
        let w = TestWindow.new(id: 13, parent: focus.workspace.rootTilingContainer)
        w.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 100, topLeftY: 200, width: 300, height: 400)
        let snap: [UInt32: CgWindowInfo] = [13: CgWindowInfo(title: nil, rect: Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4))]
        let resolved = try await WindowWithPrefetchedTitle.resolveWindow(w, fromSnapshot: snap)
        assertEquals(resolved.rect?.topLeftX, 100) // cached layout rect, not the snapshot rect (1)
        assertEquals(resolved.rect?.width, 300)
    }

    @MainActor
    func testSnapshotRectUsedWhenNoCachedRect() async throws {
        setUpWorkspacesForTests()
        // No rect passed to .new and no cached layout rect → snapshot bounds are used.
        let w = TestWindow.new(id: 14, parent: focus.workspace.rootTilingContainer)
        let snap: [UInt32: CgWindowInfo] = [14: CgWindowInfo(title: nil, rect: Rect(topLeftX: 7, topLeftY: 8, width: 9, height: 10))]
        let resolved = try await WindowWithPrefetchedTitle.resolveWindow(w, fromSnapshot: snap)
        assertEquals(resolved.rect?.topLeftX, 7)
        assertEquals(resolved.rect?.width, 9)
    }
}
