import Common

/// Why `name` isn't a section of `workspace`, or nil (workspace-sections)
@MainActor
func sectionError(_ name: String, _ workspace: Workspace) -> String? {
    guard let sections = workspace.sections else {
        return "Workspace '\(workspace.name)' has no sections (workspace-sections in the config)"
    }
    if sections.index(of: name) != nil { return nil }
    return "Workspace '\(workspace.name)' has no section '\(name)'. Its sections: \(sections.sections.map(\.name).joined(separator: ", "))"
}

/// workspace-sections: `window` goes to the end of section `name` of its workspace
@MainActor
func moveWindowToSection(_ window: Window, _ name: String, _ io: CmdIo, failIfNoop: Bool) -> BinaryExitCode {
    guard let workspace = window.nodeWorkspace else {
        return .fail(io.err("Window \(window.windowId) doesn't belong to any workspace"))
    }
    if let error = sectionError(name, workspace) { return .fail(io.err(error)) }
    guard window.parent is TilingContainer else {
        return .fail(io.err("Window \(window.windowId) isn't tiled: only tiled windows are in sections"))
    }
    if window.sectionName == name {
        return switch failIfNoop {
            case true: .fail
            case false:
                .succ(io.err("Window '\(window.windowId)' is already in section '\(name)'. Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    window.bind(to: workspace.sectionForWindows(name), adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    return .succ
}
