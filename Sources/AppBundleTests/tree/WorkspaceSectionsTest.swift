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
}
