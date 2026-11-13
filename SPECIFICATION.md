# SleepControl — specification

SleepControl is a macOS menu-bar utility. It keeps the Mac awake with the lid closed
(also on battery, with no external display). It is a clean-room rewrite of the
behaviour of the open-source "Sleepless" app. Do not copy code from that app.

Target: Apple Silicon, macOS 13.0 or later (the owner runs macOS 15.8).
Toolchain: Command Line Tools `swiftc` (Swift 6.2). No Xcode project, no Package.swift,
no third-party dependencies, no network access of any kind.

## 1. Mechanism

- ON:  `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1`
- OFF: `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0`
- The setting is runtime-only; macOS resets it to 0 at reboot.
- A sudoers drop-in at `/etc/sudoers.d/sleepcontrol` (root:wheel, mode 0440) permits
  exactly these two argument vectors for one user, with NOPASSWD:
  `<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1`

## 2. Resource rules (the main difference from the original)

1. NO polling timer. NO subprocess to read state.
2. Read the current state from the IORegistry: service `IOPMrootDomain`
   (`IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))`),
   boolean property `"SleepDisabled"`. Release every IOKit object.
3. Read battery state with `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` /
   `IOPSGetPowerSourceDescription` (keys `kIOPSPowerSourceStateKey`,
   `kIOPSCurrentCapacityKey`, `kIOPSMaxCapacityKey`, `kIOPSIsChargingKey`).
4. React to changes with notifications only:
   - `IOPSNotificationCreateRunLoopSource` (power source or percent changed),
   - `NSProcessInfoPowerStateDidChange` (Low Power Mode changed),
   - `NSWorkspace.didWakeNotification` (re-read state after wake).
5. The only subprocesses are: `sudo -n pmset` on a user action, a safety action or quit,
   and `osascript` for the permission install, the permission removal and the rare
   automatic-off notification.
6. Use one auto-off `Timer` only while an auto-off duration is active. No 1 Hz timer.
7. Idle CPU use must be 0%. Resident memory must stay small (target below 30 MB).

## 3. Security rules

1. Never run a script file from the app bundle as root.
2. The permission install builds the sudoers line in Swift. The user name comes from
   `NSUserName()` and must match `^[A-Za-z_][A-Za-z0-9_.-]{0,31}$`; refuse otherwise.
3. The root command (one `do shell script ... with administrator privileges`) must:
   write the line to a `mktemp` file, check it with `/usr/sbin/visudo -cf`, then
   `/usr/bin/install -m 0440 -o root -g wheel` it to `/etc/sudoers.d/sleepcontrol`,
   then remove the temporary file. Quote every value correctly for shell and AppleScript.
4. Provide "Remove Permission…" in the menu. With one administrator prompt it runs
   `pmset -a disablesleep 0 && rm -f /etc/sudoers.d/sleepcontrol`, so the rule stays
   when pmset fails.
5. No network APIs, no analytics, no crash reporters, no update checks, no logging to
   files. `os_log`/`NSLog` for errors only.
6. Pass `Process` an explicit minimal environment: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.
   Use absolute executable paths. Set standard input to the null device.

## 4. Behaviour

- At launch: read the TRUE state. Never turn sleep prevention on by itself.
- At quit (`applicationWillTerminate`): always send the off command. A crash or a force
  quit cannot run this step; then a restart or the app's toggle restores sleep.
- A failed automatic OFF is retried every 60 seconds until it succeeds or prevention is off.
- Timers and the power-source run-loop source use the common run-loop modes, so they
  also fire while an alert is open.
- Cancelling an administrator prompt is not an error and shows no alert.
- Safety rules, checked on every power notification while prevention is ON:
  1. On battery power and percent <= floor → turn OFF and notify. This rule always wins.
  2. On battery power and Low Power Mode on → turn OFF and notify, unless the user turned
     prevention on while Low Power Mode was already on.
- Auto-off timer: Never / 1 hour / 2 hours / 4 hours. Starts when prevention turns on
  (or when the user selects a duration while it is on). When it fires → turn OFF and notify.
  Turning prevention off cancels the timer. The selected duration is remembered.
- Battery floor choices: 10 %, 15 %, 20 %, 30 %, 50 %. Default 15 %. Remembered in
  `UserDefaults` key `batteryFloorPercent`. Auto-off choice in key `autoOffMinutes`.
- Launch at login: `SMAppService.mainApp` register/unregister. Off by default.
- Notifications: `osascript -e 'display notification ...'` with correctly escaped text,
  only for automatic OFF events (rare). Keep it simple.
- If `sudo -n` fails because the grant is missing (stderr contains "password is
  required" or "not allowed" or "may not run"), show an `NSAlert` that explains the
  one-time setup, then run the permission install, then retry once.

## 5. User interface

A standard `NSMenu` attached to an `NSStatusItem` (no custom popover, no custom views).

Menu-bar icon: template image drawn in code (Sources/StatusIcon.swift): a side view of a nearly closed laptop. OFF = outline; ON = light in the gap plus two rays.
Tooltip states the mode. Menu (rebuilt or updated in `menuNeedsUpdate(_:)`):

```
Keep Awake with Lid Closed        (checkmark when ON)
Status: <one line, e.g. "On · auto-off in 1 h 42 min" or "Off · sleeps normally">  (disabled)
---
Auto-Off  ▸  Never / 1 Hour / 2 Hours / 4 Hours     (checkmark on selected)
Battery Floor ▸ 10 % / 15 % / 20 % / 30 % / 50 %    (checkmark on selected)
Launch at Login                    (checkmark)
---
Remove Permission…
Quit SleepControl                  (⌘Q)
```

## 6. Source layout and interfaces (fixed; every module must use these names)

```
Sources/PowerMonitor.swift      — IOKit reads and power notifications
Sources/PrivilegedControl.swift — sudo toggle, permission install/remove, notifications
Sources/AppController.swift     — @main entry, NSStatusItem, NSMenu, timers, safety rules
Info.plist
scripts/build_application.sh    — swiftc build, bundle assembly, ad-hoc signing
scripts/install_application.sh  — build + copy to /Applications (no sudo)
scripts/uninstall_application.sh— restore sleep, remove app, login item, grant
README.md
```

### PowerMonitor.swift

```swift
struct BatteryStatus: Equatable {
    let isOnBattery: Bool     // power source state == kIOPSBatteryPowerValue
    let percent: Int          // 0...100; 100 when no battery is present
    let hasBattery: Bool
}

@MainActor
final class PowerMonitor {
    /// Called on the main thread after any power-source, Low Power Mode or wake event.
    var onChange: (() -> Void)?
    init()
    func start()               // installs the run-loop source and observers; idempotent
    func stop()
    static func readSleepDisabled() -> Bool       // IORegistry "SleepDisabled"
    static func readBatteryStatus() -> BatteryStatus
    static var isLowPowerModeEnabled: Bool { get } // ProcessInfo
}
```

The IOPS callback is a C function pointer. Pass `self` with `Unmanaged` and hop to the
main actor safely (`MainActor.assumeIsolated` is correct, because the source is on the
main run loop).

### PrivilegedControl.swift

```swift
enum ToggleResult: Equatable { case success, permissionMissing, failure(String) }
enum AdministratorResult: Equatable { case success, cancelled, failure }

enum PrivilegedControl {
    static func setSleepDisabled(_ disabled: Bool) -> ToggleResult
    static func isPermissionInstalled() -> Bool   // FileManager.fileExists at the drop-in path
    static func canInstallPermission() -> Bool     // NSUserName() passes the name rule
    static func installPermission() -> AdministratorResult  // one administrator prompt
    static func removePermission() -> AdministratorResult   // one administrator prompt
    static func postNotification(title: String, message: String)
}
```

### AppController.swift

Contains `@main enum SleepControlApplication` with a `@MainActor static func main()`,
and `final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate`.
Compile with `-parse-as-library`.

## 7. Build

```
swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  Sources/*.swift -o build/SleepControl
```

Bundle: `build/SleepControl.app/Contents/{Info.plist, MacOS/SleepControl}`.
Info.plist: `CFBundleIdentifier` = `local.sleepcontrol.SleepControl`, `LSUIElement` = true,
`LSMinimumSystemVersion` = 13.0, `CFBundleExecutable` = SleepControl. No icon file.
Ad-hoc sign: `codesign --force --sign - build/SleepControl.app`.
Use the default language mode of the compiler. The build must produce zero warnings.
