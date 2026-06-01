import Common

// Temporarily merge a donor workspace's windows into a host workspace's tree (AwesomeWM-style
// "toggle tag view"). State is ephemeral: any workspace switch dissolves all active merges.
// Ported from rafascar/AeroSpace (feat: add workspace --view-toggle).

@MainActor
func performViewToggle(hostWorkspace: Workspace, donorWorkspaceName: String) {
    // If already toggled, toggle OFF
    if let existingIndex = hostWorkspace.viewToggledStates.firstIndex(where: { $0.donorWorkspaceName == donorWorkspaceName }) {
        dissolveViewToggle(hostWorkspace: hostWorkspace, stateIndex: existingIndex)
        return
    }

    // Toggle ON
    let donorWorkspace = Workspace.get(byName: donorWorkspaceName)
    let donorIsLessThanHost = donorWorkspace < hostWorkspace

    let tilingChildren = Array(donorWorkspace.rootTilingContainer.children)
    let floatingWindows = donorWorkspace.floatingWindows

    var movedNodes: [(node: TreeNode, originalBinding: BindingData)] = []

    // Move tiling children (prepend if donor < host, append if donor > host)
    for child in tilingChildren {
        let binding = child.unbindFromParent()
        let index = donorIsLessThanHost ? movedNodes.count : INDEX_BIND_LAST
        child.bind(to: hostWorkspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: index)
        movedNodes.append((node: child, originalBinding: binding))
    }

    // Move floating windows (always append)
    for window in floatingWindows {
        let binding = window.unbindFromParent()
        window.bind(to: hostWorkspace, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        movedNodes.append((node: window, originalBinding: binding))
    }

    hostWorkspace.viewToggledStates.append(ViewToggleState(
        donorWorkspaceName: donorWorkspaceName,
        movedNodes: movedNodes,
    ))
}

@MainActor
func dissolveViewToggle(hostWorkspace: Workspace, stateIndex: Int) {
    let state = hostWorkspace.viewToggledStates[stateIndex]
    // Restore in reverse order to preserve original indices
    for (node, originalBinding) in state.movedNodes.reversed() {
        // Skip nodes that were moved elsewhere by the user during the merge
        guard node.parent != nil, node.nodeWorkspace === hostWorkspace else { continue }
        let safeIndex = min(originalBinding.index, originalBinding.parent.children.count)
        node.bind(to: originalBinding.parent, adaptiveWeight: originalBinding.adaptiveWeight, index: safeIndex)
    }
    hostWorkspace.viewToggledStates.remove(at: stateIndex)
}

@MainActor
func dissolveViewToggles(workspace: Workspace) {
    // Dissolve in reverse order (last merged = first dissolved)
    while let lastIndex = workspace.viewToggledStates.indices.last {
        dissolveViewToggle(hostWorkspace: workspace, stateIndex: lastIndex)
    }
}
