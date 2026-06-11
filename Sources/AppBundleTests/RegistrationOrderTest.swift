@testable import AppBundle
import Common
import XCTest

final class RegistrationOrderTest: XCTestCase {
    func testSortsLeftToRightThenTopToBottomNilLast() {
        let items: [(id: String, rect: Rect?)] = [
            ("a", Rect(topLeftX: 100, topLeftY: 0, width: 10, height: 10)),
            ("b", Rect(topLeftX: 0, topLeftY: 50, width: 10, height: 10)),
            ("c", Rect(topLeftX: 0, topLeftY: 0, width: 10, height: 10)),
            ("d", nil),
        ]
        let order = sortedForRegistration(items, rectOf: { $0.rect }).map { $0.id }
        assertEquals(order, ["c", "b", "a", "d"])
    }

    func testStableForEqualRects() {
        let r = Rect(topLeftX: 5, topLeftY: 5, width: 1, height: 1)
        let items: [(id: Int, rect: Rect?)] = [(1, r), (2, r), (3, r)]
        let order = sortedForRegistration(items, rectOf: { $0.rect }).map { $0.id }
        assertEquals(order, [1, 2, 3]) // ties keep original order
    }
}
