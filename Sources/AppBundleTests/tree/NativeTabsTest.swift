@testable import AppBundle
import XCTest

final class NativeTabsTest: XCTestCase {
    func testResolvesInactiveNativeTabBackingWindows() {
        let groups = resolveNativeTabWindowGroups(from: [
            NativeTabWindowCandidate(
                windowId: 10,
                title: "active",
                tabGroup: NativeTabGroupInfo(tabs: [
                    NativeTabState(title: "active", isSelected: true),
                    NativeTabState(title: "inactive", isSelected: false),
                ]),
            ),
            NativeTabWindowCandidate(windowId: 11, title: "inactive", tabGroup: nil),
            NativeTabWindowCandidate(windowId: 12, title: "standalone", tabGroup: nil),
        ])

        XCTAssertEqual(groups, [
            NativeTabWindowGroup(activeWindowId: 10, memberWindowIds: [10, 11]),
        ])
        XCTAssertEqual(groups.singleOrNil()?.inactiveWindowIds, [11])
    }

    // Mirrors the `values.count >= 2` short-circuit in MacApp.nativeTabGroups(): fewer than two
    // backing windows can never form a group, so skipping the AX walk in that case is behavior-safe.
    func testNoBackingWindowsYieldsNoGroups() {
        XCTAssertEqual(resolveNativeTabWindowGroups(from: []), [])
    }

    func testDoesNotCreateGroupWhenOnlyActiveTabWindowIsVisibleToAx() {
        let groups = resolveNativeTabWindowGroups(from: [
            NativeTabWindowCandidate(
                windowId: 10,
                title: "active",
                tabGroup: NativeTabGroupInfo(tabs: [
                    NativeTabState(title: "active", isSelected: true),
                    NativeTabState(title: "inactive", isSelected: false),
                ]),
            ),
        ])

        XCTAssertEqual(groups, [])
    }

    func testDuplicateTabTitlesConsumeOneBackingWindowPerTitleOccurrence() {
        let groups = resolveNativeTabWindowGroups(from: [
            NativeTabWindowCandidate(
                windowId: 10,
                title: "Recents",
                tabGroup: NativeTabGroupInfo(tabs: [
                    NativeTabState(title: "Recents", isSelected: false),
                    NativeTabState(title: "Recents", isSelected: true),
                    NativeTabState(title: "Home", isSelected: false),
                ]),
            ),
            NativeTabWindowCandidate(windowId: 11, title: "Recents", tabGroup: nil),
            NativeTabWindowCandidate(windowId: 12, title: "Home", tabGroup: nil),
        ])

        XCTAssertEqual(groups, [
            NativeTabWindowGroup(activeWindowId: 10, memberWindowIds: [10, 11, 12]),
        ])
    }

    func testSelectedTabTitleChoosesActiveWindowCandidate() {
        let tabGroup = NativeTabGroupInfo(tabs: [
            NativeTabState(title: "inactive", isSelected: false),
            NativeTabState(title: "active", isSelected: true),
        ])
        let groups = resolveNativeTabWindowGroups(from: [
            NativeTabWindowCandidate(windowId: 10, title: "inactive", tabGroup: tabGroup),
            NativeTabWindowCandidate(windowId: 11, title: "active", tabGroup: tabGroup),
        ])

        XCTAssertEqual(groups, [
            NativeTabWindowGroup(activeWindowId: 11, memberWindowIds: [10, 11]),
        ])
    }

    func testExtractsNativeTabGroupInfoFromAxChildren() {
        let selectedTab = NativeTabAxElement([
            Ax.subroleAttr.key: "AXTabButton" as NSString,
            Ax.titleAttr.key: "Selected" as NSString,
            Ax.valueBoolAttr.key: true as NSNumber,
        ])
        let inactiveTab = NativeTabAxElement([
            Ax.subroleAttr.key: "AXTabButton" as NSString,
            Ax.titleAttr.key: "Inactive" as NSString,
            Ax.valueBoolAttr.key: false as NSNumber,
        ])
        let tabGroup = NativeTabAxElement([
            Ax.roleAttr.key: "AXTabGroup" as NSString,
            Ax.childrenAttr.key: [selectedTab, inactiveTab] as NSArray,
        ])
        let window = NativeTabAxElement([
            Ax.childrenAttr.key: [tabGroup] as NSArray,
        ])

        XCTAssertEqual(window.nativeTabGroupInfo(), NativeTabGroupInfo(tabs: [
            NativeTabState(title: "Selected", isSelected: true),
            NativeTabState(title: "Inactive", isSelected: false),
        ]))
    }
}

private final class NativeTabAxElement: AxUiElementMock {
    private let attributes: [String: AnyObject]

    init(_ attributes: [String: AnyObject]) {
        self.attributes = attributes
    }

    func get<Attr>(_ attr: Attr) -> Attr.T? where Attr: ReadableAttr {
        attributes[attr.key].flatMap(attr.getter)
    }

    func containingWindowId() -> CGWindowID? {
        nil
    }
}
