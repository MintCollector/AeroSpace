import Common
import Foundation

/// Deterministic spatial order for placing a batch of windows into the tiling tree: left→right
/// (topLeftX), then top→bottom (topLeftY). Windows without a known rect sort last. Ties are broken
/// by original position so the result is stable (Swift's `sort` is not guaranteed stable).
///
/// This governs the fallback placement path (windows with no closed-windows-cache record). Without
/// it, a re-placed batch lands in Swift dictionary key order (hash-randomized), so a window that was
/// on the left can reappear on the right.
func sortedForRegistration<T>(_ items: [T], rectOf: (T) -> Rect?) -> [T] {
    func key(_ r: Rect?) -> (CGFloat, CGFloat) {
        guard let r else { return (.greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        return (r.topLeftX, r.topLeftY)
    }
    return items.enumerated()
        .sorted { lhs, rhs in
            let lk = key(rectOf(lhs.element))
            let rk = key(rectOf(rhs.element))
            return lk == rk ? lhs.offset < rhs.offset : lk < rk
        }
        .map(\.element)
}
