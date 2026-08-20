import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks, toStandardError: true)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var warnedSilentSystem = false
    private var warnedSilentMic = false

    /// How long to let a track run before concluding that pure silence means
    /// broken rather than quiet. Long enough that a meeting which simply opens
    /// quietly doesn't trip it; short enough to still save the meeting.
    private static let silentTrackGrace: TimeInterval = 30

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            warnedSilentSystem = false
            warnedSilentMic = false
            menuBar.updateWarning(nil)
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        // .common, not the default mode: an open NSMenu puts the main run loop
        // into NSEventTrackingRunLoopMode, where a default-mode timer stops
        // firing — freezing the elapsed counter exactly while the user is
        // looking at it.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopSession() {
        guard let session else { return }
        let silent = [
            session.systemTrackHasSignal ? nil : "system audio",
            session.micTrackHasSignal ? nil : "mic",
        ].compactMap { $0 }
        let alreadyWarned = warnedSilentSystem || warnedSilentMic
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        // A session shorter than the grace period never reached the live
        // check, and clearing the warning here would erase it at the exact
        // moment the user walks away from a broken recording. State it as the
        // fact it is — the track really did capture nothing — rather than as a
        // diagnosis, since a genuinely silent short session looks identical.
        if silent.isEmpty {
            menuBar.updateWarning(nil)
        } else {
            let tracks = silent.joined(separator: " and ")
            menuBar.updateWarning("⚠︎ last session captured no \(tracks)")
            if !alreadyWarned {
                FileHandle.standardError.write(Data(
                    "warning: session captured no \(tracks)\n".utf8
                ))
                notifyUser(
                    title: "quill — silent track",
                    body: "That session captured no \(tracks). Run `quill doctor` to check why."
                )
            }
        }

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Date().timeIntervalSince(session.startedAt)
        menuBar.update(recording: true, elapsed: Self.format(elapsed))
        checkTracks(session, elapsed: elapsed)
    }

    /// An unauthorized process tap doesn't fail — it delivers correctly-clocked
    /// digital silence, which is indistinguishable from a quiet meeting until
    /// you read the transcript the next day. Surface it while the meeting is
    /// still running. See .issues/rca-002.
    private func checkTracks(_ session: RecordingSession, elapsed: TimeInterval) {
        guard elapsed >= Self.silentTrackGrace else { return }

        if !warnedSilentSystem, !session.systemTrackHasSignal {
            warnedSilentSystem = true
            warn(
                menu: "system audio is silent — the other side won't be recorded",
                title: "quill — system audio not being captured",
                body: "Only your mic is recording. Grant System Audio Recording, and launch quill from launchd or an app bundle rather than a terminal."
            )
        }
        // The mic has its own first-second recovery for one known-bad route
        // (rca-001), but that only covers the voice-processing path. Anything
        // else that yields a silent mic — a muted or wrong input device — has
        // no recovery and would otherwise go unnoticed until playback.
        if !warnedSilentMic, !session.micTrackHasSignal {
            warnedSilentMic = true
            warn(
                menu: "mic is silent — your side isn't being recorded",
                title: "quill — microphone not being captured",
                body: "The mic track is silent. Check the input device and that it isn't muted."
            )
        }
    }

    private func warn(menu: String, title: String, body: String) {
        menuBar.updateWarning("⚠︎ \(menu)")
        FileHandle.standardError.write(Data("warning: \(menu)\n".utf8))
        notifyUser(title: title, body: body)
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
