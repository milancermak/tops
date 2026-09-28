import CoreAudio
import Foundation

struct SystemVolumeSnapshot: Equatable {
    var percent: Double
    var available: Bool
}

@MainActor
protocol SystemVolumeControlling: AnyObject {
    var snapshot: SystemVolumeSnapshot { get }
    var onChange: ((SystemVolumeSnapshot) -> Void)? { get set }
    func setVolume(_ percent: Double) throws
    func stop()
}

struct SystemVolumeRoute: Equatable {
    let id: AudioDeviceID
    let channels: [AudioObjectPropertyElement]
    let muteChannels: [AudioObjectPropertyElement]
}

/// Removing the exact registered blocks also makes releasing an unused model safe.
final class SystemVolumeObservation {
    private let cancel: () -> Void
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

@MainActor
protocol SystemVolumeHardware {
    func outputRoute() -> SystemVolumeRoute?
    func levels(_ route: SystemVolumeRoute) -> [Double]?
    func isMuted(_ route: SystemVolumeRoute) -> Bool
    func write(_ levels: [Double], route: SystemVolumeRoute) throws
    func unmute(_ route: SystemVolumeRoute) throws
    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation
    func observe(_ route: SystemVolumeRoute, changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation
}

/// macOS owns the volume. Listening never writes it back, so notifications cannot
/// form a feedback loop, and starting Tops never changes the system's volume.
@MainActor
final class SystemVolume: SystemVolumeControlling {
    private(set) var snapshot = SystemVolumeSnapshot(percent: 0, available: false)
    var onChange: ((SystemVolumeSnapshot) -> Void)?
    private let hardware: SystemVolumeHardware
    private var route: SystemVolumeRoute?
    private var outputObservation: SystemVolumeObservation?
    private var deviceObservation: SystemVolumeObservation?
    private var lastAudibleLevels: [Double] = []
    private var stopped = false

    init(hardware: SystemVolumeHardware? = nil) {
        self.hardware = hardware ?? CoreAudioVolumeHardware()
        outputObservation = self.hardware.observeOutput { [weak self] in self?.refreshRoute() }
        refreshRoute()
    }

    func setVolume(_ percent: Double) throws {
        guard percent.isFinite, !stopped else { return }
        // Resolve again so a drag cannot change a device that was just disconnected.
        refreshRoute()
        guard let route, snapshot.available, let current = hardware.levels(route) else {
            throw TopsError(message: "This output device does not support system volume control.")
        }
        let target = min(100, max(0, percent)) / 100
        let reference = current.contains(where: { $0 > 0 }) ? current : lastAudibleLevels
        let maximum = reference.max() ?? 0
        let levels = maximum > 0 && reference.count == current.count
            ? reference.map { target * ($0 / maximum) }
            : current.map { _ in target }
        do {
            try hardware.write(levels, route: route)
            if target > 0 { try hardware.unmute(route) }
        } catch {
            refresh()
            throw error
        }
        // Hardware may quantize the requested scalar; display its actual value.
        refresh()
    }

    func stop() {
        stopped = true
        outputObservation = nil
        deviceObservation = nil
    }

    private func refreshRoute() {
        guard !stopped else { return }
        let next = hardware.outputRoute()
        if next != route {
            deviceObservation = nil
            route = next
            lastAudibleLevels = []
            if let next {
                deviceObservation = hardware.observe(next) { [weak self] in self?.refreshRoute() }
            }
        }
        refresh()
    }

    private func refresh() {
        let updated: SystemVolumeSnapshot
        if let route, !route.channels.isEmpty, let levels = hardware.levels(route),
           levels.count == route.channels.count, levels.allSatisfy(\.isFinite), let maximum = levels.max() {
            if maximum > 0 { lastAudibleLevels = levels }
            updated = .init(percent: hardware.isMuted(route) ? 0 : min(100, max(0, maximum * 100)), available: true)
        } else {
            updated = .init(percent: 0, available: false)
        }
        if updated != snapshot {
            snapshot = updated
            onChange?(updated)
        }
    }
}

@MainActor
private final class CoreAudioVolumeHardware: SystemVolumeHardware {
    func outputRoute() -> SystemVolumeRoute? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard let device: UInt32 = read(AudioObjectID(kAudioObjectSystemObject), &address), device != kAudioObjectUnknown else { return nil }
        var main = property(kAudioDevicePropertyVolumeScalar)
        let channels: [UInt32]
        if writable(device, &main) {
            channels = [kAudioObjectPropertyElementMain]
        } else {
            var preferred = property(kAudioDevicePropertyPreferredChannelsForStereo)
            var pair: [UInt32] = [1, 2]
            var size = UInt32(MemoryLayout<UInt32>.size * pair.count)
            _ = AudioObjectGetPropertyData(device, &preferred, 0, nil, &size, &pair)
            channels = Array(Set(pair)).sorted().filter { channel in
                var address = property(kAudioDevicePropertyVolumeScalar, channel: channel)
                return writable(device, &address)
            }
        }
        var mute = property(kAudioDevicePropertyMute)
        let muteChannels = AudioObjectHasProperty(device, &mute)
            ? [kAudioObjectPropertyElementMain]
            : channels.filter { channel in
                var address = property(kAudioDevicePropertyMute, channel: channel)
                return AudioObjectHasProperty(device, &address)
            }
        return .init(id: device, channels: channels, muteChannels: muteChannels)
    }

    func levels(_ route: SystemVolumeRoute) -> [Double]? {
        var result: [Double] = []
        for channel in route.channels {
            var address = property(kAudioDevicePropertyVolumeScalar, channel: channel)
            guard let value: Float32 = read(route.id, &address) else { return nil }
            result.append(Double(value))
        }
        return result
    }

    func isMuted(_ route: SystemVolumeRoute) -> Bool {
        !route.muteChannels.isEmpty && route.muteChannels.allSatisfy { channel in
            var address = property(kAudioDevicePropertyMute, channel: channel)
            return (read(route.id, &address) as UInt32?) == 1
        }
    }

    func write(_ levels: [Double], route: SystemVolumeRoute) throws {
        for (channel, level) in zip(route.channels, levels) {
            var address = property(kAudioDevicePropertyVolumeScalar, channel: channel)
            var value = Float32(level)
            try set(route.id, &address, &value)
        }
    }

    func unmute(_ route: SystemVolumeRoute) throws {
        for channel in route.muteChannels {
            var address = property(kAudioDevicePropertyMute, channel: channel)
            guard (read(route.id, &address) as UInt32?) == 1 else { continue }
            var value: UInt32 = 0
            try set(route.id, &address, &value)
        }
    }

    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation {
        let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return observe(AudioObjectID(kAudioObjectSystemObject), addresses: [address], changed: changed)
    }

    func observe(_ route: SystemVolumeRoute, changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation {
        let addresses = route.channels.map { property(kAudioDevicePropertyVolumeScalar, channel: $0) }
            + route.muteChannels.map { property(kAudioDevicePropertyMute, channel: $0) }
            + [property(kAudioDevicePropertyDataSource), property(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)]
        return observe(route.id, addresses: addresses, changed: changed)
    }

    private func observe(_ device: AudioObjectID, addresses: [AudioObjectPropertyAddress], changed: @escaping @MainActor () -> Void) -> SystemVolumeObservation {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in changed() }
        }
        let registered = addresses.filter { property in
            var address = property
            return AudioObjectHasProperty(device, &address)
                && AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr
        }
        return SystemVolumeObservation {
            for var address in registered {
                AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
            }
        }
    }

    private func property(_ selector: AudioObjectPropertySelector, channel: UInt32 = kAudioObjectPropertyElementMain,
                          scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: channel)
    }

    private func writable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func read<T>(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> T? {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        return pointer.load(as: T.self)
    }

    private func set<T>(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress, _ value: inout T) throws {
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
        guard status == noErr else { throw TopsError(message: "Could not change system volume (Core Audio \(status)).") }
    }
}
