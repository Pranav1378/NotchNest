import Foundation
import IOKit.ps

/// Internal battery level and power state, updated by IOKit power-source notifications.
@Observable @MainActor
final class BatteryMonitor {
    private(set) var percent = 100
    private(set) var isCharging = false
    private(set) var pluggedIn = false
    private(set) var hasBattery = false
    @ObservationIgnored var onPlugIn: () -> Void = {}
    @ObservationIgnored private var source: CFRunLoopSource?

    func start() {
        update(initial: true)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update(initial: false) }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
        }
    }

    private func update(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc["Type"] as? String == "InternalBattery" else { continue }
            hasBattery = true
            let current = desc["Current Capacity"] as? Int ?? 0
            let max = desc["Max Capacity"] as? Int ?? 100
            percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            isCharging = desc["Is Charging"] as? Bool ?? false
            let plugged = desc["Power Source State"] as? String == "AC Power"
            if plugged && !pluggedIn && !initial { onPlugIn() }
            pluggedIn = plugged
        }
    }
}
