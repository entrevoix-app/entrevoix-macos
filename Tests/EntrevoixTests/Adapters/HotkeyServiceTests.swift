import XCTest
@testable import Entrevoix

final class HotkeyServiceTests: XCTestCase {
    func testEscapeRegistrationStaysDisabledWhenIdleBeforeInstallation() {
        var registration = EscapeHotkeyRegistrationState()

        XCTAssertFalse(registration.isEnabled)
        XCTAssertNil(registration.setCallbackAvailable(false))
        XCTAssertEqual(registration.install(), false)
        XCTAssertFalse(registration.isEnabled)
    }

    func testEscapeRegistrationEnablesAnActiveCallbackAfterInstallation() {
        var registration = EscapeHotkeyRegistrationState()

        XCTAssertNil(registration.setCallbackAvailable(true))
        XCTAssertEqual(registration.install(), true)
        XCTAssertTrue(registration.isEnabled)
    }

    func testEscapeRegistrationEnablesForAnActiveCallback() {
        var registration = EscapeHotkeyRegistrationState()

        _ = registration.install()

        XCTAssertEqual(registration.setCallbackAvailable(true), true)
        XCTAssertTrue(registration.isEnabled)
    }

    func testEscapeRegistrationIgnoresRepeatedCallbackAvailability() {
        var registration = EscapeHotkeyRegistrationState()

        _ = registration.install()
        XCTAssertEqual(registration.setCallbackAvailable(true), true)

        XCTAssertNil(registration.setCallbackAvailable(true))
        XCTAssertTrue(registration.isEnabled)
    }

    func testEscapeRegistrationDisablesWhenReturningToIdle() {
        var registration = EscapeHotkeyRegistrationState()

        _ = registration.install()
        _ = registration.setCallbackAvailable(true)

        XCTAssertEqual(registration.setCallbackAvailable(false), false)
        XCTAssertFalse(registration.isEnabled)
    }

    func testPrimaryAndSecondaryShortcutsEachEmitAnIndependentPressCycle() {
        var state = DictationShortcutPressState()

        XCTAssertTrue(state.handleKeyDown(for: .primary))
        XCTAssertTrue(state.handleKeyUp(for: .primary))
        XCTAssertTrue(state.handleKeyDown(for: .secondary))
        XCTAssertTrue(state.handleKeyUp(for: .secondary))
    }

    func testRepeatedPressesAndOverlappingShortcutsEmitOnlyFirstDownAndLastUp() {
        var state = DictationShortcutPressState()

        XCTAssertTrue(state.handleKeyDown(for: .primary))
        XCTAssertFalse(state.handleKeyDown(for: .primary))
        XCTAssertFalse(state.handleKeyDown(for: .secondary))
        XCTAssertFalse(state.handleKeyUp(for: .primary))
        XCTAssertTrue(state.handleKeyUp(for: .secondary))
        XCTAssertFalse(state.handleKeyUp(for: .secondary))
    }

    func testMatchingPrimaryAndSecondaryShortcutEventsProduceOnePressCycle() {
        var state = DictationShortcutPressState()

        XCTAssertTrue(state.handleKeyDown(for: .primary))
        XCTAssertFalse(state.handleKeyDown(for: .secondary))
        XCTAssertFalse(state.handleKeyUp(for: .primary))
        XCTAssertTrue(state.handleKeyUp(for: .secondary))
    }
}
