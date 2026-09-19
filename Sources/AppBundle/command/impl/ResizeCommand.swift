import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        if let window = target.windowOrNil, window.isFloating {
            guard let rect = try? await window.getAxRect(.cancellable) else { return .fail }
            let size = rect.size
            let topLeftCorner = rect.topLeftCorner
            let monitorRect = target.workspace.workspaceMonitor.rect

            let computeTopLeftCornerAndSize = { (diffSize: CGSize) -> (CGPoint, CGSize) in
                let newX = if topLeftCorner.x + size.width + diffSize.width / 2 > monitorRect.maxX {
                    max(monitorRect.minX, monitorRect.maxX - size.width - diffSize.width)
                } else {
                    max(monitorRect.minX, topLeftCorner.x - diffSize.width / 2)
                }

                let newY = if topLeftCorner.y + size.height + diffSize.height / 2 > monitorRect.maxY {
                    max(monitorRect.minY, monitorRect.maxY - size.height - diffSize.height)
                } else {
                    topLeftCorner.y - diffSize.height / 2
                }

                return (CGPoint(x: newX, y: newY), CGSize(width: size.width + diffSize.width, height: size.height + diffSize.height))
            }

            let isWidthDominant = size.width >= size.height
            let diff: CGFloat = switch (args.units.val, args.dimension.val) {
                case (.set(let unit), .width): CGFloat(unit) - size.width
                case (.set(let unit), .height): CGFloat(unit) - size.height
                case (.set(let unit), .smart): CGFloat(unit) - (isWidthDominant ? size.width : size.height)
                case (.set(let unit), .smartOpposite): CGFloat(unit) - (isWidthDominant ? size.height : size.width)
                case (.add(let unit), _): CGFloat(unit)
                case (.subtract(let unit), _): -CGFloat(unit)
            }

            let newTopLeftCorner: CGPoint
            let newSize: CGSize
            switch args.dimension.val {
                case .width:
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(CGSize(width: diff, height: 0))
                case .height:
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(CGSize(width: 0, height: diff))
                case .smart:
                    let diffSize = if isWidthDominant {
                        CGSize(width: diff, height: diff * (size.height / size.width))
                    } else {
                        CGSize(width: diff * (size.width / size.height), height: diff)
                    }
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(diffSize)
                case .smartOpposite:
                    let diffSize = if isWidthDominant {
                        CGSize(width: diff * (size.width / size.height), height: diff)
                    } else {
                        CGSize(width: diff, height: diff * (size.height / size.width))
                    }
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(diffSize)
            }
            window.setAxFrame(newTopLeftCorner, newSize)
            return .succ
        }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        if let direction = args.dimension.val.splitDirection {
            return moveSplit(candidates, direction, io)
        }

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .splitLeft, .splitRight, .splitUp, .splitDown:
                return .fail(io.err(bugPrompt())) // Handled above
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet https://github.com/nikitabobko/AeroSpace/issues/9"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return .fail }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}

extension ResizeCommand {
    /// Move the split (the border between two neighbours) in the given direction. Unlike width/height, the effect on
    /// the focused window depends on its position: the window on the left of the split grows when the split moves
    /// right, and the window on the right of the split shrinks. Only the two neighbours that share the split are
    /// resized.
    ///
    /// The split is the trailing (right/bottom) border of the focused node. If the node is the last one in its
    /// container, it's the leading (left/top) border
    @MainActor
    private func moveSplit(_ candidates: [TreeNode], _ direction: CardinalDirection, _ io: CmdIo) -> BinaryExitCode {
        let orientation = direction.orientation
        let node = candidates.first {
            guard let parent = $0.parent as? TilingContainer else { return false }
            return parent.orientation == orientation && parent.children.count > 1
        }
        guard let node, let parent = node.parent as? TilingContainer, let index = node.ownIndex else {
            return .fail(io.err("There is no split to move in the '\(direction.rawValue)' direction"))
        }
        let amount: CGFloat
        switch args.units.val {
            case .add(let unit): amount = CGFloat(unit)
            case .subtract(let unit): amount = -CGFloat(unit)
            case .set: return .fail(io.err("split-* dimensions require the number to be prefixed with '+' or '-'"))
        }
        // Positive delta moves the split right/down
        let delta = direction.isPositive ? amount : -amount
        let (before, after): (TreeNode, TreeNode) = index < parent.children.count - 1
            ? (node, parent.children[index + 1])
            : (parent.children[index - 1], node)
        let newBefore = before.getWeight(orientation) + delta
        let newAfter = after.getWeight(orientation) - delta
        if newBefore <= 0 || newAfter <= 0 { return .fail }
        before.setWeight(orientation, newBefore)
        after.setWeight(orientation, newAfter)
        return .succ
    }
}
