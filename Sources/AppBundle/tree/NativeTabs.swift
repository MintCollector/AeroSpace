import AppKit

struct NativeTabState: Equatable {
    let title: String
    let isSelected: Bool
}

struct NativeTabGroupInfo: Equatable {
    let tabs: [NativeTabState]

    var selectedTitle: String? {
        tabs.first { $0.isSelected }?.title
    }

    var titles: [String] {
        tabs.map(\.title)
    }

    var debugJson: Json {
        .array(tabs.map {
            .dict([
                "title": .string($0.title),
                "selected": .bool($0.isSelected),
            ])
        })
    }
}

struct NativeTabWindowCandidate: Equatable {
    let windowId: UInt32
    let title: String
    let tabGroup: NativeTabGroupInfo?
}

struct NativeTabWindowGroup: Equatable, Sendable {
    let activeWindowId: UInt32
    let memberWindowIds: Set<UInt32>

    var inactiveWindowIds: Set<UInt32> {
        memberWindowIds.subtracting([activeWindowId])
    }
}

extension AxUiElementMock {
    func nativeTabGroupInfo() -> NativeTabGroupInfo? {
        let children: [any AxUiElementMock] = get(Ax.childrenAttr) ?? []
        for child in children {
            guard child.get(Ax.roleAttr) == "AXTabGroup" else { continue }
            let tabChildren: [any AxUiElementMock] = child.get(Ax.childrenAttr) ?? []
            let tabs = tabChildren.compactMap { tab -> NativeTabState? in
                guard tab.get(Ax.subroleAttr) == "AXTabButton" else { return nil }
                return NativeTabState(
                    title: tab.get(Ax.titleAttr) ?? "",
                    isSelected: tab.get(Ax.valueBoolAttr) == true,
                )
            }
            if tabs.count >= 2 {
                return NativeTabGroupInfo(tabs: tabs)
            }
        }
        return nil
    }
}

func resolveNativeTabWindowGroups(from candidates: [NativeTabWindowCandidate]) -> [NativeTabWindowGroup] {
    var result: [NativeTabWindowGroup] = []
    var groupedWindowIds = Set<UInt32>()

    for candidate in candidates {
        guard !groupedWindowIds.contains(candidate.windowId),
              let tabGroup = candidate.tabGroup
        else {
            continue
        }
        let activeTitle = tabGroup.selectedTitle ?? candidate.title
        let active = candidates.first {
            !groupedWindowIds.contains($0.windowId) &&
                $0.tabGroup != nil &&
                $0.title == activeTitle
        } ?? candidate

        var memberIds: Set<UInt32> = [active.windowId]
        var matchedWindowIds: Set<UInt32> = [active.windowId]
        var remainingTitles = tabGroup.titles

        if let index = remainingTitles.firstIndex(of: activeTitle) {
            remainingTitles.remove(at: index)
        }

        for title in remainingTitles {
            guard let sibling = candidates.first(where: {
                !matchedWindowIds.contains($0.windowId) &&
                    $0.title == title
            }) else {
                continue
            }
            memberIds.insert(sibling.windowId)
            matchedWindowIds.insert(sibling.windowId)
        }

        if memberIds.count >= 2 {
            result.append(NativeTabWindowGroup(activeWindowId: active.windowId, memberWindowIds: memberIds))
            groupedWindowIds.formUnion(memberIds)
        }
    }

    return result
}
