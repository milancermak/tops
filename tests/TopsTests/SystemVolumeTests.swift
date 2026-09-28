import CoreAudio
import XCTest
@testable import Tops

@MainActor
final class SystemVolumeTests: XCTestCase {
    func testInitialAndExternalVolumeAreReadWithoutWritingBack() {
        let hardware = VolumeHardwareStub(levels: [0.3, 0.6])
        let volume = SystemVolume(hardware: hardware)
        XCTAssertEqual(volume.snapshot, .init(percent: 60, available: true))
        var changes: [SystemVolumeSnapshot] = []
        volume.onChange = { changes.append($0) }

        hardware.currentLevels = [0.2, 0.4]
        hardware.deviceChanged?()
        hardware.deviceChanged?()
        XCTAssertEqual(changes, [.init(percent: 40, available: true)])
        XCTAssertTrue(hardware.writes.isEmpty, "Reading external changes must not form a writeback loop")
    }

    func testSliderPreservesChannelBalanceAndRestoresItAfterZero() throws {
        let hardware = VolumeHardwareStub(levels: [0.3, 0.6])
        let volume = SystemVolume(hardware: hardware)
        try volume.setVolume(80)
        XCTAssertEqual(hardware.currentLevels, [0.4, 0.8])
        try volume.setVolume(0)
        XCTAssertEqual(hardware.currentLevels, [0, 0])
        try volume.setVolume(60)
        XCTAssertEqual(hardware.currentLevels[0], 0.3, accuracy: 0.00001)
        XCTAssertEqual(hardware.currentLevels[1], 0.6, accuracy: 0.00001)
        try volume.setVolume(200)
        XCTAssertEqual(volume.snapshot.percent, 100)
        try volume.setVolume(-1)
        XCTAssertEqual(volume.snapshot.percent, 0)
    }

    func testMuteFollowsSystemAndRaisingSliderUnmutes() throws {
        let hardware = VolumeHardwareStub(levels: [0.5, 0.5])
        let volume = SystemVolume(hardware: hardware)
        hardware.muted = true
        hardware.deviceChanged?()
        XCTAssertEqual(volume.snapshot.percent, 0)
        XCTAssertTrue(hardware.writes.isEmpty)
        try volume.setVolume(30)
        XCTAssertFalse(hardware.muted)
        XCTAssertEqual(volume.snapshot.percent, 30)
    }

    func testDeviceSwitchRefreshesListenersAndWritesOnlyTheNewOutput() throws {
        let hardware = VolumeHardwareStub(levels: [0.5, 0.5])
        let volume = SystemVolume(hardware: hardware)
        hardware.route = .init(id: 20, channels: [0], muteChannels: [])
        hardware.currentLevels = [0.8]
        hardware.outputChanged?()
        XCTAssertEqual(volume.snapshot.percent, 80)
        XCTAssertEqual(hardware.deviceRemovals, 1)
        XCTAssertEqual(hardware.observedDevices, [10, 20])

        // A route can change between its notification and the next slider event.
        hardware.route = .init(id: 30, channels: [0], muteChannels: [])
        hardware.currentLevels = [0.2]
        try volume.setVolume(25)
        XCTAssertEqual(hardware.writes.map(\.0), [30])
        XCTAssertEqual(volume.snapshot.percent, 25)
        let lateNotification = hardware.outputChanged
        volume.stop()
        hardware.route = .init(id: 40, channels: [0], muteChannels: [])
        lateNotification?()
        XCTAssertEqual(hardware.outputRemovals, 1)
        XCTAssertEqual(hardware.deviceRemovals, 3)
        XCTAssertEqual(hardware.observedDevices, [10, 20, 30], "A queued notification must not restart stopped listeners")
    }

    func testUnsupportedOrDisconnectedOutputCannotBeWritten() {
        let hardware = VolumeHardwareStub(levels: [])
        hardware.route = .init(id: 10, channels: [], muteChannels: [])
        let volume = SystemVolume(hardware: hardware)
        XCTAssertFalse(volume.snapshot.available)
        XCTAssertThrowsError(try volume.setVolume(40))
        hardware.route = nil
        hardware.outputChanged?()
        XCTAssertFalse(volume.snapshot.available)
        XCTAssertTrue(hardware.writes.isEmpty)
    }

    func testFailedWriteKeepsActualVolumeAndReportsError() {
        let hardware = VolumeHardwareStub(levels: [0.5, 0.5])
        hardware.failWrites = true
        let volume = SystemVolume(hardware: hardware)
        XCTAssertThrowsError(try volume.setVolume(80))
        XCTAssertEqual(volume.snapshot.percent, 50)
    }

    func testModelUsesSystemVolumeEvenWhenDisconnectedAndIgnoresEngineGain() {
        let hardware = VolumeHardwareStub(levels: [0.2, 0.2])
        let volume = SystemVolume(hardware: hardware)
        let model = AppModel(systemVolume: volume)
        XCTAssertFalse(model.connected)
        XCTAssertEqual(model.playback.volume, 20)
        XCTAssertTrue(model.playback.volumeAvailable)
        model.setVolume(40)
        XCTAssertEqual(hardware.currentLevels[0], 0.4, accuracy: 0.00001)
        XCTAssertEqual(hardware.currentLevels[1], 0.4, accuracy: 0.00001)
        model.handleEvent("playback", ["volume_percent": 100.0])
        XCTAssertEqual(model.playback.volume, 40, accuracy: 0.00001)
        hardware.currentLevels = [0.3, 0.3]
        hardware.deviceChanged?()
        XCTAssertEqual(model.playback.volume, 30)
        model.shutdown()
        XCTAssertEqual(hardware.outputRemovals, 1)
        XCTAssertEqual(hardware.deviceRemovals, 1)
    }
}

@MainActor
private final class VolumeHardwareStub: SystemVolumeHardware {
    var route: SystemVolumeRoute? = .init(id: 10, channels: [1, 2], muteChannels: [0])
    var currentLevels: [Double]
    var muted = false
    var failWrites = false
    var writes: [(AudioDeviceID, [Double])] = []
    var observedDevices: [AudioDeviceID] = []
    var outputRemovals = 0
    var deviceRemovals = 0
    var outputChanged: (@MainActor () -> Void)?
    var deviceChanged: (@MainActor () -> Void)?

    init(levels: [Double]) { currentLevels = levels }
    func outputRoute() -> SystemVolumeRoute? { route }
    func levels(_ route: SystemVolumeRoute) -> [Double]? { currentLevels }
    func isMuted(_ route: SystemVolumeRoute) -> Bool { muted }
    func write(_ levels: [Double], route: SystemVolumeRoute) throws {
        if failWrites { throw TopsError(message: "Volume write failed") }
        writes.append((route.id, levels))
        currentLevels = levels
    }
    func unmute(_ route: SystemVolumeRoute) throws { muted = false }
    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation {
        outputChanged = changed
        return .init { [weak self] in self?.outputRemovals += 1; self?.outputChanged = nil }
    }
    func observe(_ route: SystemVolumeRoute, changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation {
        observedDevices.append(route.id)
        deviceChanged = changed
        return .init { [weak self] in self?.deviceRemovals += 1; self?.deviceChanged = nil }
    }
}
