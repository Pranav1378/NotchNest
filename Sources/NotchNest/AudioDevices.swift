import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's output volume through Core Audio (no permission needed).
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// 0…1, or nil when the output (e.g. some HDMI displays) has no volume control.
    static var level: Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func set(_ level: Float) {
        guard let device = defaultOutputDevice() else { return }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = Float32(min(max(level, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        var muteAddress = self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, &muteAddress) {
            var mute = UInt32(value == 0 ? 1 : 0)
            AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        }
    }

    static func name(of device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func allDevices() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    /// True while any app is recording from (or playing to) the device.
    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    static func transport(of device: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Speakers, headphones and displays that sound can play through, for the player's output menu.
struct AudioOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return HeadphoneBattery.symbol(for: name)
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "hifispeaker.fill"
        }
    }

    static func all() -> [AudioOutput] {
        SystemVolume.allDevices()
            .filter { SystemVolume.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
            .compactMap { id in
                let transport = SystemVolume.transport(of: id)
                guard transport != kAudioDeviceTransportTypeAggregate, let name = SystemVolume.name(of: id) else { return nil }
                return AudioOutput(id: id, name: name, transport: transport)
            }
    }

    static var current: AudioOutput? {
        guard let id = SystemVolume.defaultOutputDevice(), let name = SystemVolume.name(of: id) else { return nil }
        return AudioOutput(id: id, name: name, transport: SystemVolume.transport(of: id))
    }

    /// Makes this the Mac's sound output (and alert sounds' too, as the Sound settings do).
    static func select(_ output: AudioOutput) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = output.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(system, &address, 0, nil, size, &device)
        }
        ActivityLog.note("sound output: \(output.name)")
    }
}

struct BluetoothDevice: Equatable, Identifiable {
    let name: String
    /// System Information's device type: "Mouse", "Keyboard", "Magic Trackpad", "Headphones"…
    let kind: String
    let level: Int

    var id: String { name }

    var symbol: String {
        let type = kind.lowercased()
        if type.contains("mouse") { return "magicmouse.fill" }
        if type.contains("keyboard") { return "keyboard.fill" }
        if type.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if type.contains("head") { return HeadphoneBattery.symbol(for: name) }
        return "dot.radiowaves.left.and.right"
    }
}

/// Notices when the sound output switches to Bluetooth headphones (e.g. AirPods connecting).
@MainActor
final class OutputDeviceWatcher {
    var onHeadphonesConnected: (String) -> Void = { _ in }
    private var current: AudioDeviceID?

    func start() {
        current = SystemVolume.defaultOutputDevice()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    private func outputChanged() {
        guard let device = SystemVolume.defaultOutputDevice(), device != current else { return }
        current = device
        if SystemVolume.isBluetooth(device), let name = SystemVolume.name(of: device) {
            ActivityLog.note("headphones connected: \(name)")
            onHeadphonesConnected(name)
        }
    }
}

/// Battery levels for Bluetooth headphones, as macOS reports them in System Information.
/// `system_profiler` is Apple's own tool, so this needs no Bluetooth permission.
enum HeadphoneBattery {
    struct Levels: Equatable {
        var left: Int?
        var right: Int?
        var chargingCase: Int?
        var main: Int?

        /// One number for the notch: the lower earbud, or the headphones' single battery.
        var headline: Int? { [left, right].compactMap { $0 }.min() ?? main }
    }

    static func levels(for name: String) async -> Levels? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPBluetoothDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: parse(data, name: name))
            }
        }
    }

    private static func parse(_ data: Data, name: String) -> Levels? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bluetooth = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bluetooth["device_connected"] as? [[String: Any]] else { return nil }
        let devices = connected.flatMap { $0.map { ($0.key, $0.value as? [String: Any] ?? [:]) } }
        let match = devices.first { $0.0 == name }
            ?? devices.first { $0.0.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.0) }
        guard let info = match?.1 else { return nil }
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
        }
        let levels = Levels(left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                            chargingCase: percent("device_batteryLevelCase"), main: percent("device_batteryLevelMain"))
        return levels.headline == nil ? nil : levels
    }

    /// Every connected Bluetooth device that reports a battery (mice, keyboards, trackpads, AirPods…).
    static func connectedDevices() async -> [BluetoothDevice] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPBluetoothDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: [])
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: devices(in: data))
            }
        }
    }

    static func devices(in data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bluetooth = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bluetooth["device_connected"] as? [[String: Any]] else { return [] }
        return connected.flatMap { $0.map { ($0.key, $0.value as? [String: Any] ?? [:]) } }.compactMap { name, info in
            func percent(_ key: String) -> Int? {
                (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
            }
            let levels = Levels(left: percent("device_batteryLevelLeft"), right: percent("device_batteryLevelRight"),
                                chargingCase: percent("device_batteryLevelCase"), main: percent("device_batteryLevelMain"))
            guard let level = levels.headline else { return nil }
            return BluetoothDevice(name: name, kind: info["device_minorType"] as? String ?? "", level: level)
        }
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}
