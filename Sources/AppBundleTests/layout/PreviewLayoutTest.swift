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

    /// asTiles is where `layout tiles` on every container would put each window, nested ones included
    func testAsTilesMatchesLiveTilesLayout() async throws {
        for layout in [Layout.accordion, .scrolling, .tabs] {
            setUpWorkspacesForTests()
            let ws = focus.workspace
            let root = ws.rootTilingContainer
            root.layout = layout
            TestWindow.new(id: 1, parent: root)
            let nested = TilingContainer(parent: root, adaptiveWeight: 1, .v, layout, index: INDEX_BIND_LAST)
            TestWindow.new(id: 2, parent: nested)
            TestWindow.new(id: 3, parent: nested)
            let tiled = ws.previewLayoutRects(asTiles: true)
            assertEquals(tiled.count, 3)
            root.layout = .tiles
            nested.layout = .tiles
            _ = try await ws.layoutWorkspace()
            for window in root.allLeafWindowsRecursive {
                assertEquals(tiled[window.windowId].map(components), window.lastAppliedLayoutPhysicalRect.map(components))
            }
            assertTrue(tiled[1]!.maxX <= tiled[2]!.minX) // side by side
            assertTrue(tiled[2]!.maxY <= tiled[3]!.minY) // the nested v container stacks top to bottom
        }
    }

    /// A fullscreen window covers its workspace; asTiles keeps it in its tile
    func testAsTilesPutsFullscreenWindowInItsTile() {
        let ws = focus.workspace
        let a = TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        let tile = ws.previewLayoutRects()[1]!
        a.isFullscreen = true
        a.markAsMostRecentChild()
        assertTrue(ws.previewLayoutRects()[1]!.width > tile.width)
        assertEquals(ws.previewLayoutRects(asTiles: true)[1].map(components), components(tile))
    }

    /// max-window-width goes by the columns the tiles make, not the accordion's single one
    func testAsTilesClampsByTiledColumnCount() {
        let ws = focus.workspace
        ws.rootTilingContainer.layout = .accordion
        TestWindow.new(id: 1, parent: ws.rootTilingContainer)
        TestWindow.new(id: 2, parent: ws.rootTilingContainer)
        config.maxWindowWidth = .perColumnCount([2: 300])
        let tiled = ws.previewLayoutRects(asTiles: true)
        assertEquals(tiled[1]?.width, 300)
        assertEquals(tiled[2]?.width, 300)
        assertTrue(ws.previewLayoutRects()[1]!.width > 300) // the accordion is one column: no clamp
    }

    private func components(_ r: Rect) -> [CGFloat] { [r.topLeftX, r.topLeftY, r.width, r.height] }
}
