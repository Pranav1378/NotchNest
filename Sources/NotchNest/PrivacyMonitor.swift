import CoreAudio
import CoreMediaIO
import Foundation

/// Notices when any app is using the camera or a microphone, and mutes the microphones on request.
/// Reading "is it in use" needs no permission; nothing is ever recorded.
@Observable @MainActor
final class PrivacyMonitor {
    private(set) var micInUse = false
    private(set) var cameraInUse = false
    private(set) var micMuted = false
    /// Goes up each time the camera or mic starts being used, so a hidden alert returns next call.
    private(set) var session = 0
    /// The Mirror's own camera use doesn't count.
    @ObservationIgnored var ignoreCamera: () -> Bool = { false }
    @ObservationIgnored private var timer: Timer?
    /// What muting changed on each input, so unmuting puts it back exactly.
    @ObservationIgnored private var saved: [AudioDeviceID: Saved] = [:]

    private enum Saved {
        case mute(UInt32)
        case volume([UInt32: Float32])
    }

    var isActive: Bool { micInUse || cameraInUse }

    func start() {
        poll()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if micMuted { unmute() }
    }

    func poll() {
        let mic = Self.inputs().contains(where: SystemVolume.isRunningSomewhere)
        let camera = Self.cameraRunning() && !ignoreCamera()
        if (mic || camera) && !isActive { session += 1 }
        if mic != micInUse {
            micInUse = mic
            ActivityLog.note("microphone \(mic ? "in use" : "free")")
            // Never leave the Mac's microphones muted after the call that needed it.
            if !mic && micMuted { unmute() }
        }
        if camera != cameraInUse {
            cameraInUse = camera
            ActivityLog.note("camera \(camera ? "in use" : "free")")
        }
    }

    func toggleMute() { if micMuted { unmute() } else { mute() } }

    /// Mutes every microphone, so switching mics mid-call can't slip past it.
    func mute() {
        guard !micMuted else { return }
        for device in Self.inputs() {
            if var address = Self.muteAddress(device) {
                var old = UInt32(0)
                var size = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, &old)
                var on = UInt32(1)
                if AudioObjectSetPropertyData(device, &address, 0, nil, size, &on) == noErr {
                    saved[device] = .mute(old)
                    continue
                }
            }
            // No mute switch: turn the input level down to zero instead.
            var levels: [UInt32: Float32] = [:]
            for element in Self.volumeElements(device) {
                var address = Self.volumeAddress(element)
                var old = Float32(0)
                var size = UInt32(MemoryLayout<Float32>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &old) == noErr else { continue }
                var zero = Float32(0)
                if AudioObjectSetPropertyData(device, &address, 0, nil, size, &zero) == noErr { levels[element] = old }
            }
            if !levels.isEmpty { saved[device] = .volume(levels) }
        }
        micMuted = true
        ActivityLog.note("microphones muted (\(saved.count))")
    }

    func unmute() {
        for (device, state) in saved {
            switch state {
            case .mute(let old):
                guard var address = Self.muteAddress(device) else { continue }
                var value = old
                AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            case .volume(let levels):
                for (element, old) in levels {
                    var address = Self.volumeAddress(element)
                    var value = old
                    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
                }
            }
        }
        saved.removeAll()
        micMuted = false
        ActivityLog.note("microphones unmuted")
    }

    // MARK: Core Audio

    static func inputs() -> [AudioDeviceID] {
        SystemVolume.allDevices().filter {
            SystemVolume.hasStreams($0, scope: kAudioObjectPropertyScopeInput)
                && SystemVolume.transport(of: $0) != kAudioDeviceTransportTypeAggregate
        }
    }

    private static func muteAddress(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return nil }
        return address
    }

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput,
                                   mElement: element)
    }

    /// The main element if it has a level, otherwise the first two channels.
    private static func volumeElements(_ device: AudioDeviceID) -> [UInt32] {
        let candidates: [[UInt32]] = [[kAudioObjectPropertyElementMain], [1, 2]]
        for group in candidates {
            let usable = group.filter { element in
                var address = volumeAddress(element)
                var settable = DarwinBoolean(false)
                return AudioObjectHasProperty(device, &address)
                    && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
            }
            if !usable.isEmpty { return usable }
        }
        return []
    }

    // MARK: Core Media IO

    static func cameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size = UInt32(0)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used = UInt32(0)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return false }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value = UInt32(0)
            var got = UInt32(0)
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == 0
                && value != 0
        }
    }
}
