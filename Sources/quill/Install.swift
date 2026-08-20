import ArgumentParser
import Darwin
import Foundation

/// Manage quill's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since quill ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register quill to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Build a .app bundle so quill can be launched from Spotlight/Raycast/Dock.")
    var app: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    @Option(name: .long, help: "Destination for --app (default ~/Applications/quill.app).")
    var to: String?

    func run() throws {
        guard [launchAtLogin, app, uninstall].filter({ $0 }).count == 1 else {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login, --app, or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else if app {
            try writeAppBundle()
        } else {
            try writeAgent()
        }
    }

    // MARK: - App bundle

    /// Wrap the binary in a .app.
    ///
    /// This is not cosmetic. macOS attributes the system-audio grant to the
    /// process it holds *responsible* for quill, and refuses to prompt unless
    /// that process declares `NSAudioCaptureUsageDescription`. Launchers don't
    /// (neither Ghostty nor Raycast do), so a spawned bare binary is denied
    /// silently and the tap yields digital silence. Inside a bundle, TCC reads
    /// *this* Info.plist and quill can hold its own grant no matter who starts
    /// it. See .issues/rca-002.
    private func writeAppBundle() throws {
        // Deliberately NOT resolveBinaryPath(): that prefers
        // /usr/local/bin/quill, so `swift build && .build/release/quill install
        // --app` would silently bundle whatever stale binary is installed
        // rather than the one you just built. For --app the running executable
        // is what the caller means.
        let binary = runningBinaryPath()
        let dest = to.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/quill.app")

        let fm = FileManager.default
        let macOS = dest.appendingPathComponent("Contents/MacOS")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: binary), to: macOS.appendingPathComponent("quill"))

        let plist: [String: Any] = [
            "CFBundleExecutable": "quill",
            "CFBundleIdentifier": Self.label,
            "CFBundleName": "quill",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            // Menu-bar only: no Dock icon, no window. Mirrors the .accessory
            // activation policy the daemon sets at runtime.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "NSMicrophoneUsageDescription":
                "quill records your microphone during meetings so you can transcribe them later. Audio never leaves this Mac.",
            "NSAudioCaptureUsageDescription":
                "quill records system audio (the other side of your meetings) so you can transcribe them later. Audio never leaves this Mac.",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: dest.appendingPathComponent("Contents/Info.plist"), options: .atomic)

        // Ad-hoc sign so the signature covers the bundle rather than just the
        // copied binary. Enough to run locally; handing the app to anyone else
        // needs Developer ID signing and notarization, or Gatekeeper will
        // quarantine it.
        let signed = run("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        if signed.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: codesign exited \(signed.status):\n\(signed.stderr)\n".utf8
            ))
        }

        print("✓ app bundle written")
        print("  \(dest.path)")
        print("  from:   \(binary)")
        print("  launch it from Spotlight/Raycast/Dock — quill then holds its own")
        print("  system-audio grant, so the tap works regardless of launcher.")
        print("  note: re-running this re-signs the bundle, which changes its")
        print("  cdhash and re-prompts for permissions.")
    }

    // MARK: -

    private static let label = "com.digimata.quill"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/quill.out.log",
            "StandardErrorPath": "/tmp/quill.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   /tmp/quill.out.log, /tmp/quill.err.log")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    /// The executable actually running this command, regardless of argv[0].
    private func runningBinaryPath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return CommandLine.arguments.first ?? "quill"
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/quill is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/quill"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "quill"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/quill not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the quill binary. install it to /usr/local/bin/quill first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        run("/bin/launchctl", args)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
