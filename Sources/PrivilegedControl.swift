import Foundation

/// The result of `PrivilegedControl.setSleepDisabled(_:)`.
enum ToggleResult: Equatable { case success, permissionMissing, failure(String) }

/// The result of an action that shows one administrator prompt.
/// `cancelled` means that the user dismissed the prompt. It is not an error.
enum AdministratorResult: Equatable { case success, cancelled, failure }

/// Privileged actions for SleepControl: the sudo toggle, the sudoers drop-in and notifications.
///
/// Every subprocess uses an absolute executable path, an argument array, the environment
/// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and the null device as standard input. The app writes
/// no files. Errors go to `NSLog`.
enum PrivilegedControl {

    // MARK: - Fixed paths and values

    private static let sudoPath = "/usr/bin/sudo"
    private static let pmsetPath = "/usr/bin/pmset"
    private static let osascriptPath = "/usr/bin/osascript"
    private static let sudoersPath = "/etc/sudoers.d/sleepcontrol"

    /// The temporary file lives in a directory that only root can write. In a directory that
    /// the user can write, the user could replace the file between `mktemp` and `install`.
    private static let temporaryFileTemplate = "/private/var/root/sleepcontrol.XXXXXX"

    private static let minimalEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// Lower-case fragments of sudo's standard error that mean the grant is missing.
    private static let permissionMarkers = ["password is required", "not allowed", "may not run"]

    // MARK: - Public interface

    static func setSleepDisabled(_ disabled: Bool) -> ToggleResult {
        let outcome: ProcessOutcome
        do {
            outcome = try runProcess(
                executablePath: sudoPath,
                arguments: ["-n", pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
            )
        } catch {
            NSLog("SleepControl: cannot start sudo: %@", error.localizedDescription)
            return .failure("cannot start sudo: \(error.localizedDescription)")
        }

        if outcome.status == 0 {
            return .success
        }

        let errorText = outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedErrorText = errorText.lowercased()
        if permissionMarkers.contains(where: { lowercasedErrorText.contains($0) }) {
            return .permissionMissing
        }
        return .failure(errorText.isEmpty ? "exit \(outcome.status)" : errorText)
    }

    static func isPermissionInstalled() -> Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// True when the current account name is accepted for a sudoers grant.
    /// Call this before `installPermission()`, so that the app can explain a rejected name.
    static func canInstallPermission() -> Bool {
        isValidUserName(NSUserName())
    }

    /// Installs the sudoers drop-in with one administrator prompt.
    static func installPermission() -> AdministratorResult {
        guard let script = makeInstallScript(userName: NSUserName()) else {
            NSLog("SleepControl: the user name is not valid for a sudoers grant. No change made.")
            return .failure
        }
        return runAppleScript(script, operation: "installPermission")
    }

    /// Turns sleep prevention off and removes the sudoers drop-in with one administrator prompt.
    static func removePermission() -> AdministratorResult {
        // Try the non-root reset first, as the specification orders it. Its result is ignored,
        // because the root command below runs pmset -a disablesleep 0 again before it removes the drop-in.
        _ = setSleepDisabled(false)
        return runAppleScript(makeRemoveScript(), operation: "removePermission")
    }

    static func postNotification(title: String, message: String) {
        let script = "display notification \"\(appleScriptLiteralContent(message))\" "
            + "with title \"\(appleScriptLiteralContent(title))\""
        _ = runAppleScript(script, operation: "postNotification")
    }

    /// Builds the complete AppleScript that installs the sudoers drop-in.
    /// Returns nil when the user name is not valid. Internal so that tests can call it.
    static func makeInstallScript(userName: String) -> String? {
        guard isValidUserName(userName) else { return nil }

        let sudoersLine = "\(userName) ALL=(root) NOPASSWD: "
            + "\(pmsetPath) -a disablesleep 0, \(pmsetPath) -a disablesleep 1"

        // The "&&" chain stops at the first failure, so visudo must pass before install runs.
        // The "exit_status" line runs after any failure, so rm always removes the temporary file.
        let shellCommand =
            "temporary_file=$(/usr/bin/mktemp \(temporaryFileTemplate)) && "
            + "printf '%s\\n' \(shellSingleQuoted(sudoersLine)) > \"$temporary_file\" && "
            + "/usr/sbin/visudo -cf \"$temporary_file\" && "
            + "/usr/bin/install -m 0440 -o root -g wheel \"$temporary_file\" \(sudoersPath); "
            + "exit_status=$?; rm -f \"$temporary_file\"; exit $exit_status"

        return administratorScript(shellCommand: shellCommand)
    }

    /// Builds the complete AppleScript that turns sleep prevention off and then removes the drop-in.
    /// The root shell runs pmset itself, so the removal does not depend on the sudo grant.
    /// The "&&" chain removes the drop-in only when pmset succeeds. When pmset fails, the drop-in stays,
    /// so the user can retry. The exit status is that of pmset when pmset fails, and that of rm otherwise.
    /// Internal so that tests can call it.
    static func makeRemoveScript() -> String {
        administratorScript(shellCommand: "\(pmsetPath) -a disablesleep 0 && /bin/rm -f \(sudoersPath)")
    }

    // MARK: - Validation and escaping

    /// Tests the same rule as the expression `^[A-Za-z_][A-Za-z0-9_.-]{0,31}$`.
    /// The check is written by hand, so no regular-expression anchor can match before a newline.
    private static func isValidUserName(_ userName: String) -> Bool {
        let leadingCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        let trailingCharacters = leadingCharacters.union(Set("0123456789.-"))
        guard let leadingCharacter = userName.first, leadingCharacters.contains(leadingCharacter) else {
            return false
        }
        return userName.count <= 32 && userName.dropFirst().allSatisfy { trailingCharacters.contains($0) }
    }

    /// Wraps a value in single quotes for `/bin/sh`. Each embedded single quote becomes `'\''`.
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a value for the inside of an AppleScript double-quoted string literal.
    private static func appleScriptLiteralContent(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func administratorScript(shellCommand: String) -> String {
        "do shell script \"\(appleScriptLiteralContent(shellCommand))\" with administrator privileges"
    }

    // MARK: - Process execution

    /// Runs `osascript -e` with one AppleScript source and maps the outcome to an `AdministratorResult`.
    /// A nonzero exit status with "(-128)" in standard error means that the user cancelled the prompt.
    private static func runAppleScript(_ script: String, operation: String) -> AdministratorResult {
        do {
            let outcome = try runProcess(executablePath: osascriptPath, arguments: ["-e", script])
            if outcome.status == 0 {
                return .success
            }
            // A cancelled prompt is not an error, so it is not logged.
            if outcome.standardError.contains("(-128)") {
                return .cancelled
            }
            NSLog("SleepControl: %@ failed with exit %d: %@",
                  operation, outcome.status, outcome.standardError)
            return .failure
        } catch {
            NSLog("SleepControl: %@ cannot start osascript: %@", operation, error.localizedDescription)
            return .failure
        }
    }

    /// Runs one executable with an argument array and returns its status and both output streams.
    ///
    /// Standard output is read on the calling thread. Standard error is read on a second queue.
    /// Each stream drains while the child runs, so a full pipe cannot block the child, and
    /// the two reads cannot deadlock. The output here is small, but this design does not depend on that.
    private static func runProcess(executablePath: String, arguments: [String]) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = minimalEnvironment
        process.standardInput = FileHandle.nullDevice

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        try process.run()

        let standardErrorCapture = CapturedBytes()
        let standardErrorReader = standardErrorPipe.fileHandleForReading
        let readerGroup = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: readerGroup) {
            standardErrorCapture.bytes = standardErrorReader.readDataToEndOfFile()
        }

        let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        readerGroup.wait()
        process.waitUntilExit()

        return ProcessOutcome(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutputData, as: UTF8.self),
            standardError: String(decoding: standardErrorCapture.bytes, as: UTF8.self)
        )
    }
}

/// The exit status and the two output streams of one finished process.
private struct ProcessOutcome {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

/// Carries the bytes that the standard error reader produces. The caller reads `bytes` only
/// after `DispatchGroup.wait()` returns, so the reader and the caller never access it together.
private final class CapturedBytes: @unchecked Sendable {
    var bytes = Data()
}
