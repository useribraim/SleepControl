import AppKit
import IOKit
import IOKit.ps

/// A snapshot of the internal battery. `percent` is 100 when no battery is present.
struct BatteryStatus: Equatable {
    let isOnBattery: Bool     // power source state == kIOPSBatteryPowerValue
    let percent: Int          // 0...100; 100 when no battery is present
    let hasBattery: Bool
}

/// Reports power changes by notification only. It never polls.
///
/// The run-loop source and the observers do not retain the monitor.
/// The C callback receives `self` as an unretained pointer. The owner must keep the
/// monitor alive until it calls `stop()`. Call `stop()` before the last reference goes away.
@MainActor
final class PowerMonitor {
    /// Called on the main thread after any power-source, Low Power Mode or wake event.
    var onChange: (() -> Void)?

    private var isStarted = false
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var processInfoObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {}

    /// Installs the power-source run-loop source and the two observers. Calling it again has no effect.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // The callback receives `self` without a retain. See the type comment for the lifetime rule.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { pointer in
            PowerMonitor.powerSourceDidChange(pointer)
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerSourceRunLoopSource = source
        } else {
            NSLog("SleepControl: the power source notification could not be created.")
        }

        // These notifications can arrive on any thread. Each handler hops to the main actor.
        processInfoObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.notifyChange() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.notifyChange() }
        }
    }

    /// Removes the run-loop source and both observers. Calling it when the monitor is stopped has no effect.
    func stop() {
        guard isStarted else { return }
        isStarted = false

        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            CFRunLoopSourceInvalidate(source)
            powerSourceRunLoopSource = nil
        }
        if let observer = processInfoObserver {
            NotificationCenter.default.removeObserver(observer)
            processInfoObserver = nil
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Reads the `SleepDisabled` property of the `IOPMrootDomain` registry entry. Returns false on any failure.
    static func readSleepDisabled() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)
        guard let value = property?.takeRetainedValue() else { return false }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        // The type check above makes this downcast to CFBoolean safe.
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    /// Reads the internal battery from one power source snapshot.
    static func readBatteryStatus() -> BatteryStatus {
        let noBattery = BatteryStatus(isOnBattery: false, percent: 100, hasBattery: false)

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
        else {
            return noBattery
        }
        let sources = list as [AnyObject]

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any]
            else {
                continue
            }
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else {
                continue
            }

            let state = description[kIOPSPowerSourceStateKey] as? String
            let percent = min(max(current * 100 / maximum, 0), 100)
            return BatteryStatus(
                isOnBattery: state == kIOPSBatteryPowerValue,
                percent: percent,
                hasBattery: true
            )
        }
        return noBattery
    }

    /// True when the system Low Power Mode is on.
    static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// C callback for IOPS notifications. The source is on the main run loop, so the main actor is current.
    nonisolated private static func powerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.notifyChange()
        }
    }

    private func notifyChange() {
        guard isStarted else { return }
        onChange?()
    }
}
