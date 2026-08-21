import AVFoundation
import Darwin
import Foundation

public enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

public struct Check {
    public let name: String
    public let status: CheckStatus
    public let remediation: String?

    public init(name: String, status: CheckStatus, remediation: String?) {
        self.name = name
        self.status = status
        self.remediation = remediation
    }
}

public enum DoctorReport {
    /// The checks that belong to capture. Transcription has its own check in
    /// QuillTranscribe; the caller composes them, so a consumer that links
    /// capture alone still gets a complete report of what it actually uses.
    public static func captureChecks(recordingsRoot: URL) -> [Check] {
        [checkMicrophone(), checkSystemAudio(), checkRecordingsRoot(recordingsRoot)]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects. What *is* knowable up front is whether quill will
    /// ever be allowed to ask — see `launchContext()`.
    static func checkSystemAudio() -> Check {
        switch launchContext() {
        case .responsibleForSelf:
            return Check(
                name: "system audio",
                status: .warn("grant state unknowable until first use — will prompt on first recording"),
                remediation: "if recordings still come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
            )
        case .launchedBy(let name, let declaresUsage) where declaresUsage:
            return Check(
                name: "system audio",
                status: .warn("launched by \(name), which declares NSAudioCaptureUsageDescription — the grant will be attributed to \(name), not quill"),
                remediation: "approve the prompt when it appears; the grant lives under \(name) in System Settings"
            )
        case .unknown:
            return Check(
                name: "system audio",
                status: .warn("can't determine which process macOS holds responsible for quill"),
                remediation: "launch quill under launchd or from an app bundle declaring NSAudioCaptureUsageDescription; if the system track still comes out silent, that attribution is why"
            )
        case .launchedBy(let name, _):
            return Check(
                name: "system audio",
                status: .fail("launched by \(name), which does not declare NSAudioCaptureUsageDescription — macOS will deny the tap without prompting, and the system track will be silent"),
                remediation: "run quill under launchd (`quill install --launch-at-login`), or launch it from an app bundle that declares NSAudioCaptureUsageDescription — not from a terminal"
            )
        }
    }

    /// Who macOS holds responsible for quill's system-audio capture.
    ///
    /// TCC attributes a permission request to the *responsible* process, which
    /// is quill itself only when launchd started it. Any other launcher — a
    /// terminal emulator, a launcher app — inherits that role, and tccd refuses
    /// to even display a prompt unless that launcher's bundle declares
    /// `NSAudioCaptureUsageDescription`. The refusal is silent and the tap then
    /// yields digital silence rather than an error, which is how a whole
    /// meeting gets recorded with an empty `them` track. See .issues/rca-002.
    public enum LaunchContext {
        /// Started by launchd: quill is its own responsible process, and its
        /// own embedded Info.plist carries the usage description.
        case responsibleForSelf
        /// Started by something else, which takes the responsible role.
        case launchedBy(name: String, declaresAudioCaptureUsage: Bool)
        /// The SPI is unavailable, so responsibility can't be determined.
        /// Never conflate this with `responsibleForSelf` — reporting a launch
        /// context we cannot verify as "fine" is the false negative this whole
        /// check exists to prevent.
        case unknown
    }

    /// Ask the kernel who is responsible for this process.
    ///
    /// Process ancestry is *not* the answer: responsibility is assigned at
    /// spawn and survives reparenting, so a quill started under a terminal
    /// multiplexer shows an ancestor chain of bare binaries running back to
    /// launchd while TCC still holds the original terminal responsible. Only
    /// `responsibility_get_pid_responsible_for_pid` knows. It is private SPI,
    /// hence dlsym and a conservative fallback: if it ever disappears we
    /// report the state as unknown rather than claim a launch context we
    /// cannot verify.
    public static func launchContext() -> LaunchContext {
        guard let responsible = responsiblePID() else { return .unknown }
        guard responsible != getpid() else { return .responsibleForSelf }
        guard
            let path = executablePath(of: responsible),
            let bundle = appBundle(containing: path)
        else {
            return .launchedBy(
                name: executablePath(of: responsible).map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "pid \(responsible)",
                declaresAudioCaptureUsage: false
            )
        }
        return .launchedBy(
            name: bundle.deletingPathExtension().lastPathComponent,
            declaresAudioCaptureUsage: declaresAudioCaptureUsage(bundle)
        )
    }

    private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t

    /// nil when the SPI is unavailable — treated as "can't tell", never as ok.
    private static func responsiblePID() -> pid_t? {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
            "responsibility_get_pid_responsible_for_pid"
        ) else { return nil }
        let fn = unsafeBitCast(symbol, to: ResponsiblePIDFn.self)
        let pid = fn(getpid())
        return pid > 0 ? pid : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The innermost .app directory containing `path`, if any.
    private static func appBundle(containing path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    private static func declaresAudioCaptureUsage(_ bundle: URL) -> Bool {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any]
        else { return false }
        return info["NSAudioCaptureUsageDescription"] != nil
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// `toStandardError` keeps a failure report on the same stream as the
    /// message introducing it — the LaunchAgent sends stdout and stderr to
    /// different files, so a split report reads as a bare "startup checks
    /// failed:" with the reason nowhere in sight.
    public static func print(_ checks: [Check], toStandardError: Bool = false) {
        func emit(_ line: String) {
            if toStandardError {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            } else {
                Swift.print(line)
            }
        }
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            emit("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                emit("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    public static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
