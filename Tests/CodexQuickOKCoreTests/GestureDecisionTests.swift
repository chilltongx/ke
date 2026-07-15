import CoreGraphics
import XCTest
@testable import CodexQuickOKCore

final class GestureDecisionTests: XCTestCase {
    func testMovementOverFivePointsIsDrag() {
        XCTAssertTrue(
            GestureDecision.isClick(
                start: .init(x: 0, y: 0),
                end: .init(x: 3, y: 4)
            )
        )
        XCTAssertFalse(
            GestureDecision.isClick(
                start: .init(x: 0, y: 0),
                end: .init(x: 5.1, y: 0)
            )
        )
    }
}
