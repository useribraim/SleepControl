# SleepControl

SleepControl is a macOS menu-bar utility. It keeps the Mac awake with the lid closed.
It works on battery power and without an external display.

## Features

- Turns keep-awake on and off from the menu.
- Turns keep-awake off when the battery reaches the floor you choose: 10, 15, 20, 30 or 50 percent. The default is 15 percent.
- On battery, turns keep-awake off while Low Power Mode is on. This rule does not apply if you turn on keep-awake while Low Power Mode is already on.
- Turns keep-awake off when the auto-off time ends: never, 1, 2 or 4 hours.
- Turns keep-awake off when you quit the app.
- Opens at login, when you turn on Launch at Login.

The battery floor rule always applies, even when the Low Power Mode exception applies.

## Installation

You build SleepControl from source on your own Mac. No download of a prebuilt binary is necessary, so you can read every line before it runs.

1. Install the Command Line Tools, if they are not installed. A system dialog opens. Follow it.

   ```sh
   xcode-select --install
   ```

2. Get the source code:

   ```sh
   git clone https://github.com/useribraim/SleepControl.git
   cd SleepControl
   ```

3. Build and install the app. The script compiles the app, copies it to `/Applications`, and opens it. It does not use sudo.

   ```sh
   scripts/install_application.sh
   ```

4. Find the laptop icon in the menu bar. Click it, then choose **Keep Awake with Lid Closed**.

5. On first use, SleepControl explains the one-time permission. Click **Continue**, then enter your administrator password, or use Touch ID if macOS offers it. After that, the switch works without a prompt. See Sudoers rule for what the permission allows.

6. Optional: choose **Launch at Login** in the menu to start SleepControl when you log in.

To update later, run `git pull`, then run `scripts/install_application.sh` again.

The menu-bar icon shows the state:

- **Off:** a nearly closed laptop, drawn as an outline. The Mac sleeps normally.
- **On:** the same laptop with light in the gap. The Mac stays awake with the lid closed.

## How it differs from Sleepless

- It does not poll. It reads the state through IOKit and reacts to power and wake notifications.
- Its root commands are fixed. After setup, it runs only two `pmset` commands as root, without a password. See Root commands.
- It uses a standard menu, not a custom popover.
- It turns keep-awake off at a normal quit. A crash or force quit can leave the Mac unable to sleep. See Failure cases.
- It requires macOS 13.0 or later on Apple Silicon.
- It is a clean-room rewrite. It does not copy code from Sleepless.

## Caution

Do not put a Mac that stays awake into a bag or a sleeve. The Mac can overheat.

## Requirements

- An Apple Silicon Mac.
- macOS 13.0 or later.
- Command Line Tools, which provide `swiftc`. Install them with `xcode-select --install`.

## Build

Run this command from the repository root:

```sh
scripts/build_application.sh [destination_directory]
```

The script writes `SleepControl.app` to `build/` by default. It signs the app ad hoc. It does not use sudo.

## Install script details

`scripts/install_application.sh` builds the app, quits a running copy, replaces `/Applications/SleepControl.app`, and opens it. It does not use sudo.

SleepControl asks for the administrator password once, on first use. The prompt appears when you turn on Keep Awake with Lid Closed. If you cancel the prompt, nothing changes and no error appears.

## Uninstall

Turn off Launch at Login from the menu before you uninstall.

```sh
scripts/uninstall_application.sh
```

The script restores normal sleep, quits the app, removes the app and the sudoers rule, and checks that sudo no longer runs `pmset` without a password. The script uses sudo, so the terminal asks for your password. The script prints a command that deletes saved preferences. If another sudoers file grants the same commands, the final check reports a failure. See Sudoers rule.

## Root commands

Setup runs these steps as root, after one administrator prompt:

1. Writes the sudoers line with `printf` to a temporary file made by `mktemp` in `/private/var/root`.
2. Checks the file with `visudo -cf`.
3. Installs the file to `/etc/sudoers.d/sleepcontrol` with `install -m 0440 -o root -g wheel`.
4. Removes the temporary file.

Removal runs this command as root, after one administrator prompt:

```sh
/usr/bin/pmset -a disablesleep 0 && /bin/rm -f /etc/sudoers.d/sleepcontrol
```

If the `pmset` command fails, the rule stays. You can then retry the removal.

## Sudoers rule

After you approve the one-time setup, the setup writes this line to `/etc/sudoers.d/sleepcontrol`. The file belongs to root and group wheel, with mode 0440. Replace `<user>` with your short user name.

```
<user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Account names may contain A–Z, a–z, 0–9, underscore, period and hyphen. The first character must be a letter or an underscore. The name can have at most 32 characters. The app refuses other names.

Scope of the rule:

- It applies to one user account. Any process that runs as that user can run the two listed commands without a password.
- It allows no other command through sudo. It gives no other root power.

To remove the rule, choose Remove Permission in the menu, or run the uninstall script.

If a sudoers file from another tool grants the same `pmset` commands, the uninstall script's final revocation check reports a failure. For example, the original Sleepless app can use `/etc/sudoers.d/sleepless-disablesleep`. If you no longer use that tool, remove its file:

```sh
sudo rm /etc/sudoers.d/sleepless-disablesleep
```

## Failure cases

On a normal quit, the app always sends the off command.

If the app crashes or is force quit while Keep Awake is on, the Mac cannot sleep. It stays that way until one of these happens:

- You restart the Mac.
- You open SleepControl and turn off Keep Awake.

To allow sleep now, run this command:

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

A failed automatic turn-off is retried every 60 seconds, until it succeeds or Keep Awake is off.

## Measured resource use

Idle CPU use is 0.0 %. Resident memory is about 25 to 28 MB. The executable is about 170 KB. It links only Apple system frameworks.

## Privacy

SleepControl has no network code. It sends no analytics, crash reports or update checks. It writes no log files.

To check the source, run this command from the repository root:

```sh
grep -nE 'URLSession|Network|socket|http' Sources/*.swift
```

The command must print no lines.
