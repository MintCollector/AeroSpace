import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private var focusedApp: (any AbstractApp)? {
    get async throws {
        if isUnitTest {
            return appForTests
        } else {
            check(appForTests == nil)
            return switch NSWorkspace.shared.frontmostApplication {
                case let frontmostApplication?: try await MacApp.getOrRegister(frontmostApplication)
                case nil: nil
            }
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    try await focusedApp?.getFocusedWindow(cm)
}

enum NativeFocusRead {
    case current(Window?)
    /// The app asked was no longer frontmost by the time it answered
    case stale
}

/// Native focus for the focus cache. Asking an app for its focused window is async, and refreshes
/// overlap, so a read started before an activation can finish after a later read that already saw it.
/// Adopting that late answer drags the model back to the previous app's workspace, and the next read
/// drags it forward again: the visible workspace flaps between the two. A read whose app lost the
/// front while it was being asked is dropped instead.
@MainActor
func readNativeFocus(_ cm: CancellationMode) async throws -> NativeFocusRead {
    if isUnitTest { return .current(try await getNativeFocusedWindow(cm)) }
    guard let front = NSWorkspace.shared.frontmostApplication else { return .current(nil) }
    let window = try await MacApp.getOrRegister(front)?.getFocusedWindow(cm)
    let nowFront = NSWorkspace.shared.frontmostApplication
    if nowFront?.processIdentifier == front.processIdentifier { return .current(window) }
    focusLog("[focus-cache] stale read dropped: window \(window.map { String($0.windowId) } ?? "nil") (app: \(front.localizedName ?? "?")) answered after \(nowFront?.localizedName ?? "nil") took the front")
    return .stale
}
