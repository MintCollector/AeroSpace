import AppKit
import Common

// `recheck` rules (fork-only): `on-window-detected` rules that are checked again after detection,
// whenever something their `if` can test changes. User doc: docs/guide.adoc, on-window-detected.

/// While set, rule matchers read this window's title from here instead of asking the app: an AX
/// round trip, which can wait out the 1s timeout on a busy app.
@TaskLocal var knownRuleTitle: KnownWindowTitle? = nil

struct KnownWindowTitle: Sendable {
    let windowId: UInt32
    let title: String
}

extension Window {
    /// The title as rule matchers see it: the known one while it's set for this window, else the app's
    func titleForRules(_ cm: CancellationMode) async throws -> String {
        if let known = knownRuleTitle, known.windowId == windowId { return known.title }
        return try await getTitle(cm)
    }
}
