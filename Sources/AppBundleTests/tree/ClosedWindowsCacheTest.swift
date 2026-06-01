@testable import AppBundle
import XCTest

@MainActor
final class ClosedWindowsCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRestoreSkipsMissingWindowsAndPreservesOrder() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let w1 = TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root) // w2 — will be "not yet alive" on restore
        let w3 = TestWindow.new(id: 3, parent: root)
        let frozen = FrozenContainer(root)

        // Rebuild from frozen with window 2 missing (staggered reappearance).
        root.unbindFromParent()
        let alive: [UInt32: Window] = [1: w1, 3: w3]
        restoreTreeRecursive(frozenContainer: frozen, parent: workspace, index: INDEX_BIND_LAST, lookup: { alive[$0] })

        let order = workspace.rootTilingContainer.children.compactMap { ($0 as? TestWindow)?.windowId }
        assertEquals(order, [1, 3]) // w2 skipped, w1/w3 keep relative order, no crash
    }
}
