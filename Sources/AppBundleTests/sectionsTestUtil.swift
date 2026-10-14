@testable import AppBundle
import Common

/// James's sections: left | main | right as 1 | 2 | 1, new windows in main. With his normalizations, which tests
/// otherwise turn off
@MainActor
func setUpSections(collapse: [String: Bool] = [:], workspaces: [String]? = nil) {
    config.workspaceSections = WorkspaceSections(
        sections: [
            WorkspaceSection(name: "left", width: 1, collapse: collapse["left"] ?? true),
            WorkspaceSection(name: "main", width: 2, collapse: collapse["main"] ?? true),
            WorkspaceSection(name: "right", width: 1, collapse: collapse["right"] ?? true),
        ],
        defaultSection: "main",
        workspaces: workspaces,
    )
    config.enableNormalizationFlattenContainers = true
    config.enableNormalizationOppositeOrientationForNestedContainers = true
    config.gaps = Gaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
}
