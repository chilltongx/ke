import CoreGraphics
import XCTest
@testable import CodexQuickOKCore

final class ScreenRectangleSelectorTests: XCTestCase {
    func testSelectsScreenContainingPanelCenterAtSharedBoundary() {
        let screens = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ]
        let panel = CGRect(x: 90, y: 20, width: 20, height: 20)

        XCTAssertEqual(
            ScreenRectangleSelector.preferredIndex(
                for: panel,
                among: screens
            ),
            1
        )
    }

    func testUsesGreatestIntersectionWhenCenterIsBetweenScreens() {
        let screens = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 120, y: 0, width: 100, height: 100),
        ]
        let panel = CGRect(x: 90, y: 20, width: 50, height: 20)

        XCTAssertEqual(
            ScreenRectangleSelector.preferredIndex(
                for: panel,
                among: screens
            ),
            1
        )
    }
}
