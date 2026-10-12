import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

struct SystemSnapshot {
    var cpu: Double?          // 0…1
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var download: Double      // bytes per second
    var upload: Double
}

/// CPU, memory, network speed and battery health for the status card. Samples only while the
/// card is on screen.
@Observable @MainActor
final class SystemStats {
    private(set) var snapshot: SystemSnapshot?
    private(set) var batteryHealth: Int?
    private(set) var batteryCondition: String?
    private(set) var cycleCount: Int?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCPU: (busy: UInt64, total: UInt64)?
    @ObservationIgnored private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            Task {
                let battery = await Self.batteryDetails()
                batteryHealth = battery.health
                batteryCondition = battery.condition
                cycleCount = battery.cycles
            }
            sample()
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            lastCPU = nil
            lastNetwork = nil
        }
    }

    private func sample() {
        let memory = Self.memory()
        let network = networkRates()
        snapshot = SystemSnapshot(cpu: cpuUsage(), memoryUsed: memory.used, memoryTotal: memory.total,
                                  download: network.down, upload: network.up)
    }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total, busy >= last.busy else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// Roughly what Activity Monitor calls "Memory Used": app memory + wired + compressed.
    private static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private func networkRates() -> (down: Double, up: Double) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return (0, 0) }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let data = entry.pointee.ifa_data {
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(counters.ifi_ibytes)
                sent += UInt64(counters.ifi_obytes)
            }
            cursor = entry.pointee.ifa_next
        }
        let now = Date()
        defer { lastNetwork = (received, sent, now) }
        guard let last = lastNetwork else { return (0, 0) }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds > 0 else { return (0, 0) }
        // Interface counters are 32-bit and wrap around; skip a sample rather than show nonsense.
        let down = received >= last.received ? Double(received - last.received) / seconds : 0
        let up = sent >= last.sent ? Double(sent - last.sent) / seconds : 0
        return (down, up)
    }

    /// Maximum capacity, condition and cycle count exactly as System Settings shows them, read
    /// from Apple's System Information tool.
    static func batteryDetails() async -> (health: Int?, condition: String?, cycles: Int?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                process.arguments = ["SPPowerDataType", "-json"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: (nil, nil, nil))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let sections = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["SPPowerDataType"] as? [[String: Any]]
                let info = sections?.lazy.compactMap { $0["sppower_battery_health_info"] as? [String: Any] }.first
                let health = (info?["sppower_battery_health_maximum_capacity"] as? String)
                    .flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }
                continuation.resume(returning: (health, info?["sppower_battery_health"] as? String,
                                                info?["sppower_battery_cycle_count"] as? Int))
            }
        }
    }
}

/// Keeps the Mac and its display awake, like `caffeinate -d`: until you turn it off, or for a set
/// time. It's remembered across restarts, so an update doesn't quietly let the Mac sleep.
@Observable @MainActor
final class KeepAwake {
    private(set) var isOn = false
    /// When a timed session ends; nil while it's on with no end.
    private(set) var until: Date?
    @ObservationIgnored var announce: (String) -> Void = { _ in }
    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    @ObservationIgnored private var expiry: Timer?

    /// What "awake" means.
    enum Mode: String {
        /// The screen stays on while you're working (closing the lid still sleeps the Mac).
        case screen
        /// The Mac keeps running with the lid shut. macOS only allows this by switching sleep off
        /// system-wide, which needs your admin password.
        case lidClosed

        var title: String { self == .screen ? "Screen on" : "Lid closed" }
    }

    private(set) var mode: Mode = .screen

    func toggle() { if isOn { off() } else { on(minutes: nil) } }

    /// `minutes` nil means until it's turned off.
    func on(minutes: Int?, mode: Mode = .screen) {
        if isOn && mode != self.mode { off(announcing: false) }
        self.mode = mode
        let deadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if mode == .lidClosed, !Self.setSystemSleep(disabled: true) {
            announce("Keep Awake needs your admin password for lid-closed")
            self.mode = .screen
            return
        }
        if !isOn {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "NotchNest Keep Awake" as CFString, &id)
            guard result == kIOReturnSuccess else {
                announce("Couldn't keep the Mac awake")
                return
            }
            assertion = id
            isOn = true
        }
        until = deadline
        schedule()
        remember()
        ActivityLog.note("keep awake on (\(mode.rawValue))\(minutes.map { " for \($0) min" } ?? " until turned off")")
        let what = mode == .lidClosed ? "Keep Awake with the lid closed" : "Keep Awake"
        announce(deadline == nil ? "\(what) on" : "\(what) on \(Self.describe(minutes ?? 0))")
    }

    func off(announcing: Bool = true) {
        expiry?.invalidate()
        expiry = nil
        until = nil
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        if mode == .lidClosed { _ = Self.setSystemSleep(disabled: false) }
        isOn = false
        remember()
        ActivityLog.note("keep awake off")
        if announcing { announce("Keep Awake off") }
    }

    /// Turns it back on after a restart if it was on (and a timed session hasn't run out).
    func restore() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Prefs.keepAwakeMode) ?? "") ?? .screen
        guard Prefs.bool(Prefs.keepAwake) else {
            // A crash while lid-closed was on would leave macOS unable to sleep: put it back.
            if mode == .lidClosed && Self.systemSleepDisabled() { _ = Self.setSystemSleep(disabled: false) }
            return
        }
        let saved = UserDefaults.standard.double(forKey: Prefs.keepAwakeUntil)
        if saved > 0 {
            let deadline = Date(timeIntervalSince1970: saved)
            guard deadline > Date() else {
                remember(on: false)
                return
            }
            on(minutes: Int(deadline.timeIntervalSinceNow / 60) + 1, mode: mode)
        } else {
            on(minutes: nil, mode: mode)
        }
    }

    func remaining(at now: Date = .now) -> TimeInterval? {
        until.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// "for 15 min", "for 1 hour", "for 4 hours".
    static func describe(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: return "for \(minutes) min"
        case 60: return "for 1 hour"
        default: return "for \(minutes / 60) hours"
        }
    }

    private func schedule() {
        expiry?.invalidate()
        guard let until else {
            expiry = nil
            return
        }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.off(announcing: false)
                self?.announce("Keep Awake finished")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func remember(on: Bool? = nil) {
        UserDefaults.standard.set(on ?? isOn, forKey: Prefs.keepAwake)
        UserDefaults.standard.set(until?.timeIntervalSince1970 ?? 0, forKey: Prefs.keepAwakeUntil)
        UserDefaults.standard.set(mode.rawValue, forKey: Prefs.keepAwakeMode)
    }

    /// Lid-closed needs macOS's system-wide sleep switch, which only admins can change: macOS asks
    /// for the password itself. Returns whether it worked.
    static func setSystemSleep(disabled: Bool) -> Bool {
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let script = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            ActivityLog.note("keep awake: pmset disablesleep \(disabled ? 1 : 0) failed (\(error[NSAppleScript.errorNumber] ?? "?"))")
            return false
        }
        ActivityLog.note("keep awake: system sleep \(disabled ? "disabled" : "restored")")
        return true
    }

    /// Whether macOS currently has sleep switched off (what lid-closed mode sets).
    static func systemSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return text.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.contains("1") }
    }
}

extension SystemSnapshot {
    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}
