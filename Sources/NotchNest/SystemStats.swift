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

/// Keeps the Mac and its display awake (like `caffeinate -d`) until turned off or the app quits.
@Observable @MainActor
final class KeepAwake {
    private(set) var isOn = false
    @ObservationIgnored private var assertion = IOPMAssertionID(0)

    func toggle() { if isOn { off() } else { on() } }

    func on() {
        guard !isOn else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "NotchNest Keep Awake" as CFString, &id)
        guard result == kIOReturnSuccess else { return }
        assertion = id
        isOn = true
        ActivityLog.note("keep awake on")
    }

    func off() {
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        isOn = false
        ActivityLog.note("keep awake off")
    }
}

extension SystemSnapshot {
    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}
