import AppKit
import Common

extension Workspace {
    /// The sections this workspace is a row of (workspace-sections), or nil
    @MainActor var sections: WorkspaceSections? { config.workspaceSections.flatMap { $0.applies(to: name) ? $0 : nil } }

    /// The sections that hold windows, left to right: the root's children
    @MainActor var sectionContainers: [TilingContainer] {
        rootTilingContainer.children.compactMap { ($0 as? TilingContainer)?.takeIf { $0.section != nil } }
    }

    @MainActor func sectionContainer(named name: String) -> TilingContainer? {
        sectionContainers.first { $0.section == name }
    }

    /// An empty container for section `name`, at its place in the row. The caller binds a window to it before
    /// normalization runs: normalization removes empty sections
    @MainActor func makeSection(_ name: String) -> TilingContainer {
        let sections = sections.orDie("\(self.name) has no sections")
        let index = sections.index(of: name).orDie("No section '\(name)'")
        let root = rootTilingContainer
        let position = root.children.firstIndex { child in
            ((child as? TilingContainer)?.section).flatMap(sections.index(of:)).map { $0 > index } ?? false
        } ?? root.children.count
        let container = TilingContainer(
            parent: root,
            adaptiveWeight: WEIGHT_AUTO,
            newSectionOrientation(sections.sections[index], sections),
            newSectionLayout ?? config.defaultRootContainerLayout,
            index: position,
        )
        container.section = name
        return container
    }

    /// The container of section `name`, made if it holds no windows yet. A name that isn't one of this workspace's
    /// sections, or nil, means the default section
    @MainActor func sectionForWindows(_ name: String?) -> TilingContainer {
        let sections = sections.orDie("\(self.name) has no sections")
        let name = name?.takeIf { sections.index(of: $0) != nil } ?? sections.defaultSection
        return sectionContainer(named: name) ?? makeSection(name)
    }

    /// The container whose layout stands for the workspace's: the root, or with sections the default section (else the
    /// first). `layout --root` and %{workspace-root-container-layout} go by it
    @MainActor var rootLayoutContainer: TilingContainer {
        guard let sections else { return rootTilingContainer }
        return sectionContainer(named: sections.defaultSection) ?? sectionContainers.first ?? rootTilingContainer
    }

    /// default-root-container-orientation, with 'auto' going by the section's share of the monitor
    @MainActor private func newSectionOrientation(_ section: WorkspaceSection, _ sections: WorkspaceSections) -> Orientation {
        let monitor = workspaceMonitor.visibleRect
        let width = monitor.width * CGFloat(section.width) / CGFloat(sections.totalWidth)
        return switch config.defaultRootContainerOrientation {
            case .horizontal: .h
            case .vertical: .v
            case .auto: width >= monitor.height ? .h : .v
        }
    }
}

extension TreeNode {
    /// The section this node is in, itself if it is one (workspace-sections)
    var containingSection: TilingContainer? {
        parentsWithSelf.lazy.compactMap { $0 as? TilingContainer }.first { $0.section != nil }
    }

    /// The name of the section this node is in (workspace-sections)
    var sectionName: String? { containingSection?.section }
}

extension TilingContainer {
    /// The workspace's sections when this is the root of a workspace that has them: the row of sections
    @MainActor var rowSections: WorkspaceSections? { (parent as? Workspace)?.sections }
}

extension Workspace {
    /// workspace-sections: the root is a row of sections in config order, and every tiled window is in one. A window or
    /// container that landed in the root goes to the section its window was last in, else to the default one.
    /// Without sections (any more), a section is an ordinary container
    @MainActor func normalizeSections() {
        let root = rootTilingContainer
        root.section = nil
        for child in root.children { (child as? TilingContainer)?.dropNestedSections() }
        guard let sections else {
            for section in sectionContainers { root.dissolve(section) }
            return
        }
        root.layout = .tiles
        root.setOrientation(.h)
        let mruWindow = root.mostRecentWindowRecursive
        var rebound = false
        for child in root.children {
            if let container = child as? TilingContainer, let name = container.section, sections.index(of: name) != nil {
                if let first = sectionContainer(named: name), first != container { // Two of one section: merge
                    for grandchild in container.children {
                        let binding = grandchild.unbindFromParent()
                        grandchild.bind(to: first, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
                    }
                    container.unbindFromParent()
                    rebound = true
                }
                continue
            }
            (child as? TilingContainer)?.section = nil // A section the config dropped
            child.bind(to: sectionForWindows(child.mostRecentWindowRecursive?.lastSection), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            rebound = true
        }
        let ordered = sectionContainers.sorted {
            (sections.index(of: $0.section ?? "") ?? 0) < (sections.index(of: $1.section ?? "") ?? 0)
        }
        if ordered != sectionContainers {
            for (index, section) in ordered.enumerated() {
                let binding = section.unbindFromParent()
                section.bind(to: root, adaptiveWeight: binding.adaptiveWeight, index: index)
            }
            rebound = true
        }
        if rebound {
            // A bind makes what it moved the most recent: the window that was keeps focus history's lead. Only then, or
            // the row would outrank floating windows on every refresh
            mruWindow?.markAsMostRecentChild()
        }
        for section in sectionContainers {
            for window in section.allLeafWindowsRecursive {
                window.lastSection = section.section
            }
        }
    }
}

extension TilingContainer {
    /// A section is only ever a child of the root: one nested deeper is an ordinary container
    fileprivate func dropNestedSections() {
        for case let child as TilingContainer in children {
            child.section = nil
            child.dropNestedSections()
        }
    }

    /// `section` (a child of this root) becomes an ordinary container. A side-by-side section would nest in the
    /// side-by-side row, so its windows join the row instead
    @MainActor fileprivate func dissolve(_ section: TilingContainer) {
        section.section = nil
        guard section.orientation == orientation, section.layout == layout, let index = section.ownIndex else { return }
        for (offset, child) in section.children.enumerated() {
            let binding = child.unbindFromParent()
            child.bind(to: self, adaptiveWeight: binding.adaptiveWeight, index: index + offset)
        }
        section.unbindFromParent()
    }
}
