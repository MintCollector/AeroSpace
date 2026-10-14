@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceSectionsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOnlyTheListedWorkspacesHaveSections() {
        setUpSections(workspaces: ["a"])
        assertNotNil(Workspace.get(byName: "a").sections)
        assertNil(Workspace.get(byName: "b").sections)
        config.workspaceSections = nil
        assertNil(Workspace.get(byName: "a").sections)
    }

    func testASectionTakesItsPlaceInTheRow() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 3, parent: workspace.makeSection("right"))
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        let window = TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        assertEquals(workspace.sectionContainers.map(\.section), ["left", "main", "right"])
        assertEquals(window.sectionName, "main")
        assertEquals(workspace.sectionContainer(named: "right")?.children.count, 1)
    }

    func testWindowsGoToTheDefaultSectionUnlessTheirsExists() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        assertEquals(workspace.sectionForWindows(nil).section, "main")
        assertEquals(workspace.sectionForWindows("right").section, "right")
        assertEquals(workspace.sectionForWindows("gone").section, "main") // A section the config dropped
    }

    func testANewSectionIsOrientedByItsShareOfTheMonitor() {
        setUpSections()
        config.defaultRootContainerOrientation = .auto
        let workspace = Workspace.get(byName: "a")
        assertEquals(workspace.makeSection("main").orientation, .v) // 960 wide on the 1920x1080 test monitor
        config.workspaceSections?.sections[1].width = 3
        assertEquals(workspace.makeSection("main").orientation, .h) // 1152 wide
    }

    func testTheWorkspacesLayoutIsTheDefaultSections() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        assertTrue(workspace.rootLayoutContainer === workspace.rootTilingContainer) // No sections yet
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        assertEquals(workspace.rootLayoutContainer.section, "left")
        TestWindow.new(id: 2, parent: workspace.makeSection("main"))
        assertEquals(workspace.rootLayoutContainer.section, "main")
    }

    func testWindowsInTheRootGoToASection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer) // e.g. dragged onto the empty part of a monitor
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer).lastSection = "right"
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .h_tiles([.window(1)])),
            .section("right", .h_tiles([.window(2)])),
        ]))
    }

    func testASectionKeepsItsOnlyWindowAndTheRowItsOnlySection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("left", .h_tiles([.window(1)]))]))
    }

    func testAnEmptySectionGoes() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        _ = workspace.makeSection("left")
        TestWindow.new(id: 1, parent: workspace.makeSection("main"))
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.section("main", .h_tiles([.window(1)]))]))
    }

    func testASectionTakesOverItsOnlyContainer() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .v_tiles([.window(1), .window(2)])),
        ]))
    }

    func testSectionsKeepTheirOrientation() {
        // Opposite orientations would make every section of the side-by-side row vertical
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        workspace.makeSection("main").apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([
            .section("main", .h_tiles([.window(1), .window(2)])),
        ]))
    }

    func testSectionsFollowTheConfigOrderAndMerge() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        let root = workspace.rootTilingContainer
        for (id, name) in [(3, "right"), (1, "left"), (2, "left")] as [(UInt32, String)] {
            // As the closed-windows cache or a view toggle could leave them
            TilingContainer.newHTiles(parent: root, adaptiveWeight: 1).apply {
                $0.section = name
                TestWindow.new(id: id, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([
            .section("left", .h_tiles([.window(1), .window(2)])),
            .section("right", .h_tiles([.window(3)])),
        ]))
    }

    func testWithoutSectionsTheyAreOrdinaryContainers() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.makeSection("main").apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        config.workspaceSections = nil
        workspace.normalizeContainers()
        // main was side by side in the side-by-side row: its windows join the row instead of turning vertical
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    func testWindowsRememberTheirSection() {
        setUpSections()
        let workspace = Workspace.get(byName: "a")
        let window = TestWindow.new(id: 1, parent: workspace.makeSection("left"))
        workspace.normalizeContainers()
        assertEquals(window.lastSection, "left")
    }

    func testSectionsCutTheRowByTheirWidths() {
        setUpSections()
        let rects = sectionedWorkspace(["left", "main", "right"]).previewLayoutRects()
        assertEquals(ids.map { rects[$0]?.topLeftX }, [0, 480, 1440])
        assertEquals(ids.map { rects[$0]?.width }, [480, 960, 480])
    }

    func testAnEmptySectionGivesItsWidthAway() {
        setUpSections()
        let rects = sectionedWorkspace(["main"]).previewLayoutRects()
        assertEquals(rects[2]?.topLeftX, 0)
        assertEquals(rects[2]?.width, 1920)
    }

    func testAnEmptySectionThatDoesntCollapseKeepsItsSlot() {
        setUpSections(collapse: ["right": false])
        let rects = sectionedWorkspace(["main"]).previewLayoutRects()
        assertEquals(rects[2]?.topLeftX, 0)
        assertEquals(rects[2]?.width, 1280) // main 2, right 1 of the 1920
    }

    func testSectionsAreApartByTheInnerGap() {
        setUpSections()
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
        let rects = sectionedWorkspace(["left", "main", "right"]).previewLayoutRects()
        assertEquals(ids.map { rects[$0]?.topLeftX }, [0, 485, 1445])
        assertEquals(ids.map { rects[$0]?.width }, [475, 950, 475])
    }

    func testLayoutPutsWindowsInTheirSections() async throws {
        setUpSections()
        let workspace = sectionedWorkspace(["main", "right"])
        _ = try await workspace.layoutWorkspace()
        let right = try await Window.get(byId: 3).orDie().getAxRect(.nonCancellable).orDie()
        assertEquals(right.topLeftX, 1280)
        assertEquals(right.width, 640)
    }

    /// Windows 1, 2, 3 in left, main, right
    private let ids: [UInt32] = [1, 2, 3]

    /// Workspace "a" with a window in each of `sections`: 1 in left, 2 in main, 3 in right
    private func sectionedWorkspace(_ sections: [String]) -> Workspace {
        let workspace = Workspace.get(byName: "a")
        for (id, name) in [(1, "left"), (2, "main"), (3, "right")] as [(UInt32, String)] where sections.contains(name) {
            TestWindow.new(id: id, parent: workspace.makeSection(name))
        }
        return workspace
    }
}
