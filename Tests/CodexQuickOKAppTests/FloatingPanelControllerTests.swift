import XCTest
@testable import CodexQuickOKApp

@MainActor
final class FloatingPanelControllerTests: XCTestCase {
    func testReduceMotionSkipsContinuousAnimations() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { true }
        )

        controller.show(mode: .waiting)
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))

        controller.setSending(true)
        XCTAssertNil(controller.button.layer?.animation(forKey: "sending"))

        controller.hide()
    }

    func testModeRefreshDoesNotReplaceSuccessFeedback() {
        let controller = FloatingPanelController(
            positionStore: PanelPositionStore(
                defaults: UserDefaults(suiteName: #function)!
            ),
            reduceMotion: { false }
        )

        controller.show(mode: .waiting)
        controller.showSuccess()
        controller.show(mode: .running)

        XCTAssertNotNil(controller.button.layer?.animation(forKey: "success"))
        XCTAssertNil(controller.button.layer?.animation(forKey: "presence"))

        controller.hide()
    }
}
