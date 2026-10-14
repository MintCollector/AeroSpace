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
