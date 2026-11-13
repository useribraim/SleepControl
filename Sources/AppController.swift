import AppKit
import os
import ServiceManagement

/// The application entry point. The static property keeps the delegate alive,
/// because NSApplication holds its delegate weakly.
@main
enum SleepControlApplication {
    @MainActor private static var applicationController: AppController?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        applicationController = controller
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

/// Owns the status item, the menu, the auto-off timer and the battery safety rules.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Fixed values

    private static let batteryFloorKey = "batteryFloorPercent"
    private static let autoOffMinutesKey = "autoOffMinutes"
    private static let batteryFloorChoices = [10, 15, 20, 30, 50]
    private static let autoOffChoices = [0, 60, 120, 240]
    private static let defaultBatteryFloor = 15
    private static let defaultAutoOffMinutes = 0
    private static let notificationTitle = "SleepControl"
    private static let automaticOffRetryInterval: TimeInterval = 60
    private static let logger = Logger(subsystem: "local.sleepcontrol.SleepControl", category: "AppController")

    // MARK: - State

    /// The sleep state read from the system. Only `refreshFromSystem()` assigns this value.
    private var isOn = false

    /// True when the user turned prevention on while Low Power Mode was already on.
    private var allowLowPowerOverride = false

    /// The one-shot timer for the auto-off duration. Nil when no auto-off is active.
    private var autoOffTimer: Timer?

    /// The moment when the auto-off timer fires. Nil when no auto-off is active.
    private var autoOffEndDate: Date?

    /// The one-shot timer that repeats a failed automatic turn-off. Nil when no retry is pending.
    private var automaticOffRetryTimer: Timer?

    /// True after the failure notification of the current failure sequence. Reset when prevention turns off.
    private var hasReportedAutomaticOffFailure = false

    // MARK: - Objects

    private let powerMonitor = PowerMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let keepAwakeOffImage = StatusIcon.make(isOn: false)
    private let keepAwakeOnImage = StatusIcon.make(isOn: true)

    // MARK: - Menu (built once, updated in menuNeedsUpdate(_:))

    private lazy var menu: NSMenu = {
        let mainMenu = NSMenu(title: "SleepControl")
        mainMenu.autoenablesItems = false
        mainMenu.delegate = self
        mainMenu.addItem(keepAwakeItem)
        mainMenu.addItem(statusLineItem)
        mainMenu.addItem(.separator())
        mainMenu.addItem(makeSubmenuItem(title: "Auto-Off", submenu: autoOffMenu))
        mainMenu.addItem(makeSubmenuItem(title: "Battery Floor", submenu: batteryFloorMenu))
        mainMenu.addItem(launchAtLoginItem)
        mainMenu.addItem(.separator())
        mainMenu.addItem(removePermissionItem)
        mainMenu.addItem(makeMenuItem(
            title: "Quit SleepControl",
            action: #selector(quitSelected(_:)),
            keyEquivalent: "q"))
        return mainMenu
    }()

    private lazy var keepAwakeItem = makeMenuItem(
        title: "Keep Awake with Lid Closed",
        action: #selector(keepAwakeSelected(_:)))

    private lazy var statusLineItem: NSMenuItem = {
        let item = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }()

    private lazy var autoOffMenu = makeChoiceMenu(
        title: "Auto-Off",
        values: AppController.autoOffChoices,
        action: #selector(autoOffSelected(_:)),
        itemTitle: AppController.autoOffTitle(for:))

    private lazy var batteryFloorMenu = makeChoiceMenu(
        title: "Battery Floor",
        values: AppController.batteryFloorChoices,
        action: #selector(batteryFloorSelected(_:)),
        itemTitle: { "\($0) %" })

    private lazy var launchAtLoginItem = makeMenuItem(
        title: "Launch at Login",
        action: #selector(launchAtLoginSelected(_:)))

    private lazy var removePermissionItem = makeMenuItem(
        title: "Remove Permission…",
        action: #selector(removePermissionSelected(_:)))

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = menu
        powerMonitor.onChange = { [weak self] in
            self?.handlePowerChange()
        }
        powerMonitor.start()
        refreshFromSystem()
        evaluateSafetyRules()
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerMonitor.stop()
        cancelAutoOffTimer()
        cancelAutomaticOffRetry()
        // setSleepDisabled(false) is idempotent, so it runs whether or not Keep Awake is on.
        let result = PrivilegedControl.setSleepDisabled(false)
        if let failure = describeFailure(result) {
            AppController.logger.error("Keep Awake was not turned off at quit: \(failure, privacy: .public)")
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ updatedMenu: NSMenu) {
        refreshFromSystem()
        keepAwakeItem.state = isOn ? .on : .off
        statusLineItem.title = statusLineTitle()
        for item in autoOffMenu.items {
            item.state = (item.representedObject as? Int) == autoOffMinutes ? .on : .off
        }
        for item in batteryFloorMenu.items {
            item.state = (item.representedObject as? Int) == batteryFloorPercent ? .on : .off
        }
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        removePermissionItem.isEnabled = PrivilegedControl.isPermissionInstalled()
    }

    // MARK: - Menu actions

    @objc private func keepAwakeSelected(_ sender: NSMenuItem) {
        let enable = !isOn
        let unchangedState = enable ? "off" : "on"
        var result = PrivilegedControl.setSleepDisabled(enable)

        if result == .permissionMissing {
            guard PrivilegedControl.canInstallPermission() else {
                showMessage(
                    messageText: "Account Name Not Accepted",
                    informativeText: "The account name contains characters that SleepControl does not accept, "
                        + "or it is longer than 32 characters. Keep Awake stays \(unchangedState).")
                refreshFromSystem()
                return
            }
            guard confirmPermissionInstall(enabling: enable) else {
                refreshFromSystem()
                return
            }
            switch PrivilegedControl.installPermission() {
            case .success:
                result = PrivilegedControl.setSleepDisabled(enable)
            case .cancelled:
                refreshFromSystem()
                return
            case .failure:
                showMessage(
                    messageText: "Permission Not Installed",
                    informativeText: "The permission was not installed. Keep Awake stays \(unchangedState).")
                refreshFromSystem()
                return
            }
        }
        completeKeepAwakeChange(result, enabling: enable)
    }

    @objc private func autoOffSelected(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int,
              AppController.autoOffChoices.contains(minutes) else {
            return
        }
        autoOffMinutes = minutes
        restartAutoOffTimer()
    }

    @objc private func batteryFloorSelected(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int,
              AppController.batteryFloorChoices.contains(percent) else {
            return
        }
        batteryFloorPercent = percent
        evaluateSafetyRules()
    }

    @objc private func launchAtLoginSelected(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    showMessage(
                        messageText: "Approval Needed",
                        informativeText: "Allow SleepControl under Login Items in System Settings.")
                }
            }
        } catch {
            showMessage(messageText: "Launch at Login Not Changed", informativeText: error.localizedDescription)
        }
    }

    @objc private func removePermissionSelected(_ sender: NSMenuItem) {
        let response = runAlert(
            style: .warning,
            messageText: "Remove the SleepControl permission?",
            informativeText: "Keep Awake turns off first. macOS asks for the administrator password once.",
            buttonTitles: ["Remove", "Cancel"])
        guard response == .alertFirstButtonReturn else {
            return
        }
        switch PrivilegedControl.removePermission() {
        case .success, .cancelled:
            break
        case .failure:
            showMessage(
                messageText: "Permission Not Removed",
                informativeText: "The permission was not removed. Try again.")
        }
        refreshFromSystem()
    }

    @objc private func quitSelected(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Keep Awake state

    private func handlePowerChange() {
        refreshFromSystem()
        evaluateSafetyRules()
    }

    /// Reads the true sleep state. Keeps the dependent state in step with it.
    private func refreshFromSystem() {
        let wasOn = isOn
        isOn = PowerMonitor.readSleepDisabled()
        if isOn {
            if !wasOn {
                restartAutoOffTimer()
            }
        } else {
            allowLowPowerOverride = false
            cancelAutoOffTimer()
            cancelAutomaticOffRetry()
            hasReportedAutomaticOffFailure = false
        }
        updateStatusItemAppearance()
    }

    private func completeKeepAwakeChange(_ result: ToggleResult, enabling: Bool) {
        switch result {
        case .success:
            if enabling {
                allowLowPowerOverride = PowerMonitor.isLowPowerModeEnabled
            }
        case .permissionMissing:
            showMessage(
                messageText: "Keep Awake Not Changed",
                informativeText: enabling
                    ? "The permission is still missing. Keep Awake stays off."
                    : "The permission is still missing, so the sleep setting cannot change. Keep Awake stays on until the Mac restarts.")
        case .failure(let detail):
            AppController.logger.error("Keep Awake was not changed: \(detail, privacy: .public)")
            showMessage(messageText: "Keep Awake Not Changed", informativeText: detail)
        }
        refreshFromSystem()
        if enabling {
            evaluateSafetyRules()
        }
    }

    /// Turns prevention off without user action, then sends a notification.
    /// A failed attempt schedules a retry. The failure notification is posted once per failure sequence.
    private func turnOffAutomatically(reason: String) {
        let result = PrivilegedControl.setSleepDisabled(false)
        refreshFromSystem()
        guard let failure = describeFailure(result) else {
            PrivilegedControl.postNotification(title: AppController.notificationTitle, message: reason)
            return
        }
        AppController.logger.error("Automatic turn-off failed: \(failure, privacy: .public)")
        if !hasReportedAutomaticOffFailure {
            hasReportedAutomaticOffFailure = true
            PrivilegedControl.postNotification(
                title: AppController.notificationTitle,
                message: "Keep Awake is still on. \(failure)")
        }
        scheduleAutomaticOffRetry(reason: reason)
    }

    /// Applies the battery rules while prevention is on. The battery floor rule always wins.
    private func evaluateSafetyRules() {
        guard isOn else {
            return
        }
        let battery = PowerMonitor.readBatteryStatus()
        guard battery.isOnBattery else {
            return
        }
        let floor = batteryFloorPercent
        if battery.percent <= floor {
            turnOffAutomatically(reason: "The battery reached the \(floor) % floor. The Mac can sleep again.")
        } else if PowerMonitor.isLowPowerModeEnabled && !allowLowPowerOverride {
            turnOffAutomatically(reason: "Low Power Mode is on while the Mac runs on battery. The Mac can sleep again.")
        }
    }

    // MARK: - Auto-off timer

    /// Cancels any running timer. Starts a new one when prevention is on and an auto-off duration is set.
    private func restartAutoOffTimer() {
        cancelAutoOffTimer()
        let minutes = autoOffMinutes
        guard isOn, minutes > 0 else {
            return
        }
        let interval = TimeInterval(minutes * 60)
        autoOffEndDate = Date(timeIntervalSinceNow: interval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.autoOffTimerFired()
            }
        }
        // The common modes keep the timer firing while menus or modal alerts run the run loop.
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    private func cancelAutoOffTimer() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffEndDate = nil
    }

    private func autoOffTimerFired() {
        autoOffTimer = nil
        autoOffEndDate = nil
        refreshFromSystem()
        guard isOn else {
            return
        }
        turnOffAutomatically(reason: "The auto-off time ended. The Mac can sleep again.")
    }

    // MARK: - Automatic turn-off retry

    /// Schedules one one-shot retry, 60 seconds later. An earlier pending retry is invalidated first.
    private func scheduleAutomaticOffRetry(reason: String) {
        cancelAutomaticOffRetry()
        guard isOn else {
            return
        }
        let timer = Timer(timeInterval: AppController.automaticOffRetryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.automaticOffRetryFired(reason: reason)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        automaticOffRetryTimer = timer
    }

    private func cancelAutomaticOffRetry() {
        automaticOffRetryTimer?.invalidate()
        automaticOffRetryTimer = nil
    }

    /// Reads the true state again. Turns prevention off again with the same reason when it is still on.
    private func automaticOffRetryFired(reason: String) {
        automaticOffRetryTimer = nil
        refreshFromSystem()
        guard isOn else {
            return
        }
        turnOffAutomatically(reason: reason)
    }

    // MARK: - Status item and menu text

    private func updateStatusItemAppearance() {
        statusItem.button?.image = isOn ? keepAwakeOnImage : keepAwakeOffImage
        statusItem.button?.toolTip = isOn ? "SleepControl: Keep Awake is on" : "SleepControl: Keep Awake is off"
    }

    private func statusLineTitle() -> String {
        guard isOn else {
            return "Status: Off · sleeps normally"
        }
        guard let endDate = autoOffEndDate else {
            return "Status: On · no auto-off"
        }
        let remaining = AppController.remainingTimeText(endDate.timeIntervalSinceNow)
        return "Status: On · auto-off in \(remaining)"
    }

    // MARK: - Permission and login item

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func confirmPermissionInstall(enabling: Bool) -> Bool {
        let response = runAlert(
            style: .informational,
            messageText: enabling
                ? "Allow SleepControl to keep the Mac awake?"
                : "Allow SleepControl to let the Mac sleep again?",
            informativeText: "macOS asks for your administrator password once. "
                + "The permission allows only these commands: pmset -a disablesleep 0 and pmset -a disablesleep 1.",
            buttonTitles: ["Continue", "Cancel"])
        return response == .alertFirstButtonReturn
    }

    // MARK: - Persisted choices

    private var batteryFloorPercent: Int {
        get {
            AppController.storedChoice(
                forKey: AppController.batteryFloorKey,
                choices: AppController.batteryFloorChoices,
                fallback: AppController.defaultBatteryFloor)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppController.batteryFloorKey)
        }
    }

    private var autoOffMinutes: Int {
        get {
            AppController.storedChoice(
                forKey: AppController.autoOffMinutesKey,
                choices: AppController.autoOffChoices,
                fallback: AppController.defaultAutoOffMinutes)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppController.autoOffMinutesKey)
        }
    }

    // MARK: - Helpers

    private func describeFailure(_ result: ToggleResult) -> String? {
        switch result {
        case .success:
            return nil
        case .permissionMissing:
            return "The SleepControl permission is missing."
        case .failure(let detail):
            return detail
        }
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func makeSubmenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func makeChoiceMenu(
        title: String,
        values: [Int],
        action: Selector,
        itemTitle: (Int) -> String
    ) -> NSMenu {
        let choiceMenu = NSMenu(title: title)
        for value in values {
            let item = makeMenuItem(title: itemTitle(value), action: action)
            item.representedObject = value
            choiceMenu.addItem(item)
        }
        return choiceMenu
    }

    @discardableResult
    private func runAlert(
        style: NSAlert.Style,
        messageText: String,
        informativeText: String,
        buttonTitles: [String]
    ) -> NSApplication.ModalResponse {
        activateApplication()
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = messageText
        alert.informativeText = informativeText
        for buttonTitle in buttonTitles {
            alert.addButton(withTitle: buttonTitle)
        }
        return alert.runModal()
    }

    private func showMessage(messageText: String, informativeText: String) {
        runAlert(
            style: .warning,
            messageText: messageText,
            informativeText: informativeText,
            buttonTitles: ["OK"])
    }

    /// Brings this accessory application to the front, so that an alert is visible.
    private func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Returns the stored value when it is an allowed choice. Otherwise returns the fallback.
    private static func storedChoice(forKey key: String, choices: [Int], fallback: Int) -> Int {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int,
              choices.contains(value) else {
            return fallback
        }
        return value
    }

    nonisolated private static func autoOffTitle(for minutes: Int) -> String {
        switch minutes {
        case 60:
            return "1 Hour"
        case 120:
            return "2 Hours"
        case 240:
            return "4 Hours"
        default:
            return "Never"
        }
    }

    /// Formats a time span as "1 h 42 min", "2 h" or "45 min". Shows at least one minute.
    private static func remainingTimeText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        if minutes == 0 {
            return "\(hours) h"
        }
        return "\(hours) h \(minutes) min"
    }
}
