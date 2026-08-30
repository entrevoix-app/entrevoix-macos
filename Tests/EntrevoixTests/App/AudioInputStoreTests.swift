import XCTest
import EntrevoixCore
@testable import Entrevoix

final class AudioInputStoreTests: XCTestCase {
    @MainActor
    func testSelectingDevicePersistsImmediatelyAndSortsDevices() {
        let preferencesStore = PreferencesStoreSpy()
        let deviceZ = AudioInputDeviceReference(uid: "z", name: "Zoom Mic")
        let deviceA = AudioInputDeviceReference(uid: "a", name: "AirPods")
        let catalog = AudioInputDeviceCatalogSpy(snapshot: .init(
            devices: [deviceZ, deviceA],
            defaultDeviceUID: deviceZ.uid
        ))
        let preferences = PreferencesStore(
            preferencesStore: preferencesStore,
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences()
        )
        let model = AudioInputStore(preferencesStore: preferences, deviceCatalog: catalog)

        model.setSelection(.device(deviceA))

        XCTAssertEqual(model.devices, [deviceA, deviceZ])
        XCTAssertEqual(model.defaultDevice, deviceZ)
        XCTAssertEqual(preferencesStore.saved.last?.audioInputSelection, .device(deviceA))
    }

    @MainActor
    func testSelectingSystemDefaultPersistsImmediately() {
        let selected = AudioInputDeviceReference(uid: "external", name: "Studio Microphone")
        let persistence = PreferencesStoreSpy()
        let preferences = PreferencesStore(
            preferencesStore: persistence,
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(audioInputSelection: .device(selected))
        )
        let model = AudioInputStore(
            preferencesStore: preferences,
            deviceCatalog: AudioInputDeviceCatalogSpy()
        )

        model.setSelection(.systemDefault)

        XCTAssertEqual(model.selection, .systemDefault)
        XCTAssertEqual(persistence.saved.last?.audioInputSelection, .systemDefault)
    }

    @MainActor
    func testMissingSelectionIsRetainedAndClearsWhenDeviceReconnects() {
        let selected = AudioInputDeviceReference(uid: "external", name: "Studio Microphone")
        let catalog = AudioInputDeviceCatalogSpy(snapshot: .init(devices: [], defaultDeviceUID: nil))
        let preferences = PreferencesStore(
            preferencesStore: PreferencesStoreSpy(),
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(audioInputSelection: .device(selected))
        )
        let model = AudioInputStore(preferencesStore: preferences, deviceCatalog: catalog)

        XCTAssertEqual(model.unavailableSelection, selected)

        catalog.replaceSnapshot(.init(devices: [selected], defaultDeviceUID: selected.uid))

        XCTAssertNil(model.unavailableSelection)
        XCTAssertEqual(model.selection, .device(selected))
    }

    @MainActor
    func testReconnectingSelectionRefreshesItsLastKnownName() {
        let stored = AudioInputDeviceReference(uid: "external", name: "Old Name")
        let connected = AudioInputDeviceReference(uid: "external", name: "New Name")
        let persistence = PreferencesStoreSpy()
        let catalog = AudioInputDeviceCatalogSpy(snapshot: .init(devices: [], defaultDeviceUID: nil))
        let preferences = PreferencesStore(
            preferencesStore: persistence,
            keychain: SecretStoreSpy(),
            initialPreferences: AppPreferences(audioInputSelection: .device(stored))
        )
        let model = AudioInputStore(preferencesStore: preferences, deviceCatalog: catalog)

        catalog.replaceSnapshot(.init(devices: [connected], defaultDeviceUID: connected.uid))

        XCTAssertNil(model.unavailableSelection)
        guard case .device(let persisted)? = persistence.saved.last?.audioInputSelection else {
            return XCTFail("Expected the connected microphone to be saved")
        }
        XCTAssertEqual(persisted.uid, connected.uid)
        XCTAssertEqual(persisted.name, connected.name)
    }
}
