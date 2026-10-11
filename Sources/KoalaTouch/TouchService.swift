import AppKit
import Foundation

/// The MPC Touch's touch driver (mpc_touchd, LaunchAgent com.savilion.mpc-touchd), shared with Paper Cut: installed for
/// this user from Koala Link's own copy if it isn't there yet, then started or restarted. This never opens the SiS USB
/// device or sends the MPC's display-on MIDI command.
enum TouchService {
    private static let label = "com.savilion.mpc-touchd"
    private static let driverName = "mpc_touchd"

    struct Result {
        let ready: Bool
        let message: String
        let recoveryAttempted: Bool
    }

    static func prepare(mpcDisplayID: UInt32?, allowRecovery: Bool, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = prepareOnWorker(mpcDisplayID: mpcDisplayID, allowRecovery: allowRecovery)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func prepareOnWorker(mpcDisplayID: UInt32?, allowRecovery: Bool) -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let driver = home.appendingPathComponent("Library/Application Support/MPC Touch Driver/\(driverName)")
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let log = home.appendingPathComponent("Library/Logs/mpc_touchd.log")
        if !FileManager.default.fileExists(atPath: driver.path) || !FileManager.default.fileExists(atPath: plist.path) {
            guard allowRecovery else {
                return Result(ready: false, message: "The touch driver isn't installed yet.", recoveryAttempted: false)
            }
            // Not installed (Koala Link's installer leaves it until an MPC Touch is connected): install it now, for this
            // user only, from the copy inside Koala Link. A new driver needs the Accessibility permission once.
            let installed = installDriver()
            if !installed.ok {
                return Result(ready: false, message: "The touch driver couldn't be installed: \(installed.output)", recoveryAttempted: true)
            }
            if installed.new {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                return Result(ready: false, message: "Touch driver installed. Allow mpc_touchd in Privacy & Security › Accessibility; Koala Link carries on by itself.", recoveryAttempted: true)
            }
        }

        let service = "gui/\(getuid())/\(label)"
        let loaded = runLaunchctl(["print", service])
        var attempted = false
        if loaded.status != 0 {
            guard allowRecovery else { return Result(ready: false, message: "Touch service is not loaded.", recoveryAttempted: false) }
            let started = runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
            attempted = true
            if started.status != 0 {
                return Result(ready: false, message: "Could not start the installed touch service: \(started.output)", recoveryAttempted: true)
            }
        } else {
            let running = loaded.output.contains("state = running")
            let mapped = screenMapped(in: log, expectedDisplayID: mpcDisplayID)
            if !running || (mpcDisplayID != nil && mapped != true) {
                guard allowRecovery else {
                    return Result(ready: false, message: "Touch service needs a restart.", recoveryAttempted: false)
                }
                let restarted = runLaunchctl(["kickstart", "-k", service])
                attempted = true
                if restarted.status != 0 {
                    return Result(ready: false, message: "Could not restart the installed touch service: \(restarted.output)", recoveryAttempted: true)
                }
            }
        }

        // Paper Cut's installed v3 service can retain a "screen arrived late"
        // result. Wait for its own log to confirm mapping before offering touch.
        for _ in 0..<24 {
            let current = runLaunchctl(["print", service])
            if current.status == 0 && current.output.contains("state = running") {
                if screenMapped(in: log, expectedDisplayID: mpcDisplayID) == true {
                    return Result(ready: true, message: "MPC touch ready", recoveryAttempted: attempted)
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let message = mpcDisplayID != nil
            ? "The touch driver is running, but the MPC's screen isn't mapped yet (waiting for it)…"
            : "The MPC Touch's screen isn't there yet (DisplayLink). Koala Link carries on when macOS sees it."
        return Result(ready: false, message: message, recoveryAttempted: attempted)
    }

    /// Runs Koala Link's bundled install-for-user.sh with its bundled TouchDriver folder (the same files Paper Cut's
    /// installer uses). Exit 0 = already up to date, 10 = a new driver was installed.
    private static func installDriver() -> (ok: Bool, new: Bool, output: String) {
        guard let script = Bundle.main.url(forResource: "install-for-user", withExtension: "sh"),
              let source = Bundle.main.resourceURL?.appendingPathComponent("TouchDriver"),
              FileManager.default.fileExists(atPath: source.appendingPathComponent(driverName).path) else {
            return (false, false, "Koala Link's copy of the driver is missing; reinstall Koala Link.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PAPERCUT_SOURCE"] = source.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return (false, false, error.localizedDescription) }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        PickerLog.write("touch driver install · exit \(process.terminationStatus) · \(output)")
        return (process.terminationStatus == 0 || process.terminationStatus == 10, process.terminationStatus == 10, output)
    }

    /// Same log boundary and status strings used by Paper Cut's ConnectionProbe.
    private static func screenMapped(in url: URL, expectedDisplayID: UInt32?) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n")
        let since = lines.lastIndex(where: { $0.contains("mpc_touchd v3 started") }).map { lines[$0...] } ?? lines[...]
        var mapped: Bool?
        for line in since where line.contains("screen (") {
            mapped = !line.contains("not present")
            if let expectedDisplayID, mapped == true {
                mapped = line.contains("display \(expectedDisplayID),")
            }
        }
        return mapped
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        // A file avoids waiting on a child whose launchctl output filled a pipe.
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("paper-picker-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: capture.path, contents: nil),
              let outputFile = try? FileHandle(forWritingTo: capture) else { return (-1, "Could not capture touch service status") }
        defer { try? outputFile.close(); try? FileManager.default.removeItem(at: capture) }
        process.standardOutput = outputFile
        process.standardError = outputFile
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date(timeIntervalSinceNow: 4)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return (-1, "Touch service command timed out") }
        let output = String(decoding: (try? Data(contentsOf: capture)) ?? Data(), as: UTF8.self)
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
