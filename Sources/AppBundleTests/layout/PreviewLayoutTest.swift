@testable import AppBundle
import Common
import XCTest

@MainActor
final class PreviewLayoutTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// The preview must match what the live pass applies, for tiles and accordion.
    func testPreviewMatchesLiveLayout() async throws {
        for layout in [Layout.tiles, .accordion] {
            setUpWorkspacesForTests()
            let ws = focus.workspace
            ws.rootTilingContainer.layout = layout
            for id: UInt32 in [1, 2, 3] { TestWindow.new(id: id, parent: ws.rootTilingContainer) }
            let preview = ws.previewLayoutRects()
            _ = try await ws.layoutWorkspace()
            let windows = ws.rootTilingContainer.allLeafWindowsRecursive
            assertEquals(windows.count, 3)
            for window in windows {
                assertEquals(preview[window.windowId].map(components), window.lastAppliedLayoutPhysicalRect.map(components))
            }
        }
    }

    func testPreviewDoesNotNormalizeWeights() {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer, adaptiveWeight: 1)
        let before = a.getWeight(.h)
        _ = ws.previewLayoutRects()
        assertEquals(a.getWeight(.h), before)
    }

    /// Hidden workspaces have no cached rect; the preview still lays them out on their monitor.
    func testHiddenWorkspaceGetsRects() {
        let hidden = Workspace.get(byName: name)
        TestWindow.new(id: 7, parent: hidden.rootTilingContainer)
        TestWindow.new(id: 8, parent: hidden.rootTilingContainer)
        assertTrue(!hidden.isVisible)
        let rects = hidden.previewLayoutRects()
        let monitor = hidden.workspaceMonitor.rect
        assertEquals(rects.count, 2)
        for r in rects.values {
            assertTrue(r.width > 0 && r.height > 0)
            assertTrue(r.minX >= monitor.minX && r.maxX <= monitor.maxX)
        }
        assertTrue(rects[7]!.minX < rects[8]!.minX) // h_tiles: side by side
    }

    private func components(_ r: Rect) -> [CGFloat] { [r.topLeftX, r.topLeftY, r.width, r.height] }
}
