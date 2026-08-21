import AppKit
import XCTest
@testable import Entrevoix

final class DockPresenceControllerTests: XCTestCase {
    @MainActor
    func testPreparingForUserFacingWindowMakesAppRegularBeforeActivationAndHidesAfterClose() {
        var events: [String] = []
        let controller = DockPresenceController(
            setActivationPolicy: { policy in
                events.append(policy == .regular ? "regular" : "accessory")
                return true
            },
            requestActivation: {
                events.append("activate")
            }
        )
        let settingsWindow = NSObject()

        controller.prepareForUserFacingWindow()
        controller.register(windowID: ObjectIdentifier(settingsWindow))
        controller.unregister(windowID: ObjectIdentifier(settingsWindow))

        XCTAssertEqual(events, ["regular", "activate", "accessory"])
        XCTAssertFalse(controller.isDockVisible)
    }

    @MainActor
    func testPreparingForAnAlreadyRegisteredWindowOnlyRequestsActivation() {
        var policies: [NSApplication.ActivationPolicy] = []
        var activationRequests = 0
        let controller = DockPresenceController(
            setActivationPolicy: { policy in
                policies.append(policy)
                return true
            },
            requestActivation: {
                activationRequests += 1
            }
        )
        let settingsWindow = NSObject()
        let windowID = ObjectIdentifier(settingsWindow)

        controller.register(windowID: windowID)
        controller.prepareForUserFacingWindow()
        controller.register(windowID: windowID)

        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(activationRequests, 1)
        XCTAssertTrue(controller.isDockVisible)
    }

    @MainActor
    func testFocusingARegisteredSceneRequestsItsWindowFocus() {
        var activationRequests = 0
        var focusedWindows: [ObjectIdentifier] = []
        let controller = DockPresenceController(
            setActivationPolicy: { _ in true },
            requestActivation: {
                activationRequests += 1
            },
            requestWindowFocus: { focusedWindows.append($0) }
        )
        let settingsWindow = NSObject()
        let windowID = ObjectIdentifier(settingsWindow)

        controller.register(windowID: windowID, sceneID: "settings")
        controller.focusUserFacingWindow(id: "settings")

        XCTAssertEqual(activationRequests, 1)
        XCTAssertEqual(focusedWindows, [windowID])
    }

    @MainActor
    func testShowsDockForFirstWindowAndHidesItAfterLastWindowCloses() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = DockPresenceController { policy in
            policies.append(policy)
            return true
        }
        let settingsWindow = NSObject()
        let onboardingWindow = NSObject()

        controller.register(windowID: ObjectIdentifier(settingsWindow))
        XCTAssertTrue(controller.isDockVisible)
        XCTAssertEqual(policies, [.regular])

        controller.register(windowID: ObjectIdentifier(onboardingWindow))
        controller.unregister(windowID: ObjectIdentifier(settingsWindow))
        XCTAssertTrue(controller.isDockVisible)
        XCTAssertEqual(policies, [.regular])

        controller.unregister(windowID: ObjectIdentifier(onboardingWindow))
        XCTAssertFalse(controller.isDockVisible)
        XCTAssertEqual(policies, [.regular, .accessory])
    }

    @MainActor
    func testRepeatedRegistrationAndUnregistrationAreIdempotent() {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = DockPresenceController { policy in
            policies.append(policy)
            return true
        }
        let window = NSObject()
        let windowID = ObjectIdentifier(window)

        controller.register(windowID: windowID)
        controller.register(windowID: windowID)
        controller.unregister(windowID: windowID)
        controller.unregister(windowID: windowID)

        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertFalse(controller.isDockVisible)
    }
}
