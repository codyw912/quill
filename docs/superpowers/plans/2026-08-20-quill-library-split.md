# quill library split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose quill's recording and transcription cores as two SwiftPM library products so a sibling app (quire) can link them, without changing quill's own behaviour in any observable way.

**Architecture:** `QuillCapture` (recording, config, notifications — no FluidAudio) and `QuillTranscribe` (transcription engines and coordinator — depends on FluidAudio *and* on QuillCapture, because the coordinator uses `Config` and `notifyUser`). The `quill` executable keeps its AppKit UI and `ArgumentParser` commands and links both libraries. Files move between targets; logic does not change.

**Tech Stack:** Swift 6, SwiftPM, AppKit, AVFoundation, CoreAudio, FluidAudio.

**Spec:** `/Users/cody/dev/quire/docs/superpowers/specs/2026-08-20-quire-owns-the-app-design.md` (lives in the quire repo; this plan implements its "What changes in quill" section)

## Global Constraints

- `// swift-tools-version:6.0`, `platforms: [.macOS(.v15)]` — unchanged.
- **quill's observable behaviour must not change.** Same menu bar, same `doctor` output, same `install --app` bundle, same recording. This plan is a refactor; a behavioural difference is a defect.
- The executable target must stay at `Sources/quill/` so its `-sectcreate` linker flag path (`Sources/quill/Info.plist`) keeps working. That embedded plist is what lets TCC attribute system-audio capture to quill; breaking it silently reintroduces a bug that cost a real meeting (`.issues/rca-002`).
- **This repo has no test target and this plan does not add one.** Verification is: it builds, `doctor` prints the same report, the bundle still assembles, and the embedded plist section is still present. Every task ends with those checks where applicable.
- Access control is the substance of this work. A symbol used across a module boundary needs `public`, and a `public` struct needs an explicit `public init` — Swift does not export memberwise initializers.
- Do not "improve" code while moving it. No renames, no signature changes, no reformatting beyond what access control requires.

---

### Task 1: `QuillCapture` — recording, config, notifications

**Files:**
- Modify: `Package.swift`
- Move: `Sources/quill/Config.swift` → `Sources/QuillCapture/Config.swift`
- Move: `Sources/quill/Notify.swift` → `Sources/QuillCapture/Notify.swift`
- Move: `Sources/quill/RecordingSession.swift` → `Sources/QuillCapture/RecordingSession.swift`
- Move: `Sources/quill/Audio/MicRecorder.swift` → `Sources/QuillCapture/Audio/MicRecorder.swift`
- Move: `Sources/quill/Audio/SystemAudioRecorder.swift` → `Sources/QuillCapture/Audio/SystemAudioRecorder.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: library product `QuillCapture` exporting `Config`, `notifyUser(title:body:)`, `RecordingSession`, `MicRecorder`, `SystemAudioRecorder`.

- [ ] **Step 1: Move the files with `git mv`**

```bash
cd /Users/cody/dev/quill
mkdir -p Sources/QuillCapture/Audio
git mv Sources/quill/Config.swift Sources/QuillCapture/Config.swift
git mv Sources/quill/Notify.swift Sources/QuillCapture/Notify.swift
git mv Sources/quill/RecordingSession.swift Sources/QuillCapture/RecordingSession.swift
git mv Sources/quill/Audio/MicRecorder.swift Sources/QuillCapture/Audio/MicRecorder.swift
git mv Sources/quill/Audio/SystemAudioRecorder.swift Sources/QuillCapture/Audio/SystemAudioRecorder.swift
rmdir Sources/quill/Audio
```

Use `git mv`, not copy-and-delete — it keeps the history readable.

- [ ] **Step 2: Declare the target and product in `Package.swift`**

Add to `products:` (the key is missing today — add the whole array), and add the target. The executable gains a dependency on it:

```swift
let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QuillCapture", targets: ["QuillCapture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        .target(name: "QuillCapture"),
        .executableTarget(
            name: "quill",
            dependencies: [
                "QuillCapture",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to quill itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/quill/Info.plist",
                ]),
            ]
        ),
    ]
)
```

- [ ] **Step 3: Build and let the compiler enumerate the access-control work**

Run: `swift build -c release 2>&1 | grep -E "error" | head -40`

Expected: a wall of errors of the form `cannot find 'Config' in scope`, `'RecordingSession' is inaccessible due to 'internal' protection level`, and similar. This list *is* your task list — work it until empty. Do not guess at what needs to be public; the compiler knows.

- [ ] **Step 4: Add `import QuillCapture` where needed**

`Sources/quill/Quill.swift`, `Sources/quill/Doctor.swift`, and `Sources/quill/Transcription/TranscriptionCoordinator.swift` all reference moved symbols. Add the import to each file the compiler complains about.

- [ ] **Step 5: Make the crossing symbols `public`**

The mechanical rule: anything the executable or `TranscriptionCoordinator` touches becomes `public`, and every `public` type that is constructed outside its module needs an explicit `public init`. Representative example — `RecordingSession` is constructed by `AppController`:

```swift
public final class RecordingSession {
    public let dir: URL
    public let startedAt = Date()

    public init(root: URL) throws { ... }
    public func start() throws { ... }
    public func stop() { ... }
    public var systemTrackHasSignal: Bool { system.hasSignal }
    public var micTrackHasSignal: Bool { mic.hasSignal }
}
```

Apply the same treatment to `Config`'s static methods, `notifyUser`, and `MicRecorder`/`SystemAudioRecorder`'s used surface. Leave everything the executable does *not* touch `internal` — a smaller public surface is a smaller commitment, and this fork wants to keep merging from upstream.

- [ ] **Step 6: Build clean**

Run: `swift build -c release 2>&1 | grep -E "error|warning: .*public|Build complete"`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Verify behaviour is unchanged**

```bash
.build/release/quill doctor; echo "exit: $?"
otool -s __TEXT __info_plist .build/release/quill | head -3
```

Expected: the same four checks in the same order as before this task (`microphone`, `system audio`, `recordings folder`, `transcription`), the same exit code, and a non-empty `__info_plist` section. If `doctor`'s output differs in any way, stop — that is a behavioural change and this task is a refactor.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: extract QuillCapture library

Recording, config and notifications become a library product so a sibling
app can link them. Files move; logic does not. quill's own binary links
the library and behaves identically."
```

---

### Task 2: `QuillTranscribe` — engines and coordinator

**Files:**
- Modify: `Package.swift`
- Move: `Sources/quill/Transcription/TranscriptionEngine.swift` → `Sources/QuillTranscribe/TranscriptionEngine.swift`
- Move: `Sources/quill/Transcription/ParakeetEngine.swift` → `Sources/QuillTranscribe/ParakeetEngine.swift`
- Move: `Sources/quill/Transcription/TranscriptionCoordinator.swift` → `Sources/QuillTranscribe/TranscriptionCoordinator.swift`

**Interfaces:**
- Consumes: `QuillCapture` (`Config`, `notifyUser`) from Task 1.
- Produces: library product `QuillTranscribe` exporting `TranscriptionCoordinator`, `TranscriptionEngine`, `ParakeetEngine`.

- [ ] **Step 1: Move the files**

```bash
cd /Users/cody/dev/quill
mkdir -p Sources/QuillTranscribe
git mv Sources/quill/Transcription/TranscriptionEngine.swift Sources/QuillTranscribe/TranscriptionEngine.swift
git mv Sources/quill/Transcription/ParakeetEngine.swift Sources/QuillTranscribe/ParakeetEngine.swift
git mv Sources/quill/Transcription/TranscriptionCoordinator.swift Sources/QuillTranscribe/TranscriptionCoordinator.swift
rmdir Sources/quill/Transcription
```

- [ ] **Step 2: Declare the target and product**

`QuillTranscribe` depends on `QuillCapture` — the coordinator calls `Config.onStop()`, `Config.transcriptionEnabled()` and `notifyUser`. FluidAudio moves off the executable and onto this target, since only `ParakeetEngine` imports it:

```swift
    products: [
        .library(name: "QuillCapture", targets: ["QuillCapture"]),
        .library(name: "QuillTranscribe", targets: ["QuillTranscribe"]),
    ],
    targets: [
        .target(name: "QuillCapture"),
        .target(
            name: "QuillTranscribe",
            dependencies: [
                "QuillCapture",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "quill",
            dependencies: [
                "QuillCapture",
                "QuillTranscribe",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            ...unchanged...
        ),
    ]
```

Leave FluidAudio on the executable for now — `Doctor.swift` still imports it and is still in the executable. Task 3 removes it.

- [ ] **Step 3: Build and work the error list**

Run: `swift build -c release 2>&1 | grep -E "error" | head -40`

Add `import QuillCapture` to `TranscriptionCoordinator.swift`, `import QuillTranscribe` to `Quill.swift`, and make public what the executable touches — chiefly:

```swift
public actor TranscriptionCoordinator {
    public init() { ... }
    public func setStatusHandler(_ handler: @escaping (Status) -> Void) { ... }
    public func resumePending(root: URL) { ... }
    public func enqueue(_ dir: URL) { ... }

    public enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }
}
```

Those case labels are `session:`, not `name:` — verified against the source. The
executable switches over them in `AppController.showTranscription`, so the enum
and every case must be public with its associated values and labels intact.

- [ ] **Step 4: Build clean**

Run: `swift build -c release 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 5: Verify behaviour is unchanged**

```bash
.build/release/quill doctor; echo "exit: $?"
```

Expected: identical four-check report and exit code.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: extract QuillTranscribe library

Transcription becomes a library product depending on QuillCapture, since
the coordinator uses Config and notifyUser. FluidAudio moves onto this
target — only ParakeetEngine imports it."
```

---

### Task 3: Split `Doctor` across the boundary

**Files:**
- Move/split: `Sources/quill/Doctor.swift` → `Sources/QuillCapture/Doctor.swift` and `Sources/QuillTranscribe/TranscriptionCheck.swift`
- Modify: `Sources/quill/Quill.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `QuillCapture`, `QuillTranscribe`.
- Produces: `Check`, `CheckStatus`, `DoctorReport.captureChecks(recordingsRoot:)`, `DoctorReport.print(_:toStandardError:)`, `DoctorReport.allOK(_:)` in `QuillCapture`; `TranscriptionCheck.run()` in `QuillTranscribe`.

`Doctor.swift` is the one file that cannot simply move: it imports FluidAudio for its model-cache check, while its other three checks (microphone, system audio, recordings folder) are pure capture concerns. Left whole in `QuillCapture` it drags FluidAudio into the product that exists specifically to avoid it, and quire's ability to link capture without the transcription stack silently stops holding.

- [ ] **Step 1: Move the capture half into `QuillCapture`**

```bash
cd /Users/cody/dev/quill
git mv Sources/quill/Doctor.swift Sources/QuillCapture/Doctor.swift
```

In `Sources/QuillCapture/Doctor.swift`: drop `import FluidAudio`, delete `checkTranscription()`, and rename `run(recordingsRoot:)` to `captureChecks(recordingsRoot:)` returning only the three capture checks:

```swift
public enum DoctorReport {
    /// The checks that belong to capture. Transcription has its own check in
    /// QuillTranscribe; the caller composes them, so a consumer that links
    /// capture alone still gets a complete report of what it actually uses.
    public static func captureChecks(recordingsRoot: URL) -> [Check] {
        [checkMicrophone(), checkSystemAudio(), checkRecordingsRoot(recordingsRoot)]
    }
}
```

Make `Check`, `CheckStatus`, `print(_:toStandardError:)` and `allOK(_:)` public, with public members and initializers. `launchContext()` and its helpers stay public too — quire needs them, for the same reason quill does.

- [ ] **Step 2: Put the transcription check in `QuillTranscribe`**

Create `Sources/QuillTranscribe/TranscriptionCheck.swift`, moving the body of the old `checkTranscription()` verbatim:

```swift
import FluidAudio
import Foundation
import QuillCapture

public enum TranscriptionCheck {
    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    public static func run() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }
}
```

Copy the real body from the moved file rather than trusting this transcription of it — the wording of those messages is user-facing and must not drift.

- [ ] **Step 3: Compose in the executable**

In `Sources/quill/Quill.swift`, both `Run.runMain()` and the `Doctor` subcommand build the report. Replace each `DoctorReport.run(recordingsRoot:)` call with the composition, preserving the existing order so the printed report is byte-identical:

```swift
let checks = DoctorReport.captureChecks(recordingsRoot: root) + [TranscriptionCheck.run()]
```

- [ ] **Step 4: Drop FluidAudio from the executable target**

Nothing in `Sources/quill/` imports it any more. Remove `.product(name: "FluidAudio", package: "FluidAudio")` from the `quill` executable target's dependencies in `Package.swift`, leaving it only on `QuillTranscribe`.

- [ ] **Step 5: Build clean**

Run: `swift build -c release 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`

- [ ] **Step 6: Verify the report is byte-identical**

```bash
.build/release/quill doctor > /tmp/doctor-after.txt 2>&1; echo "exit: $?"
cat /tmp/doctor-after.txt
```

Expected: the same four lines, same order, same wording, same exit code as before the split. Compare against what Task 1 Step 7 printed. Any difference is a defect, not an improvement.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: split Doctor across the capture/transcribe boundary

Doctor imported FluidAudio for its model-cache check while its other
three checks are pure capture. Left whole in QuillCapture it would drag
FluidAudio into the product that exists to avoid it. Capture checks stay,
the transcription check moves, and the executable composes both."
```

---

### Task 4: Verify quill is genuinely unchanged, and document the products

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new. This task is proof.

The whole plan claims quill's behaviour is unchanged. That claim has been checked only via `doctor` so far. This task checks the parts that actually broke a meeting once.

- [ ] **Step 1: Verify the embedded Info.plist survived**

```bash
otool -s __TEXT __info_plist .build/release/quill | head -5
```

Expected: a non-empty section. This is what lets TCC attribute system-audio capture to quill itself under launchd. If the linker flag stopped applying when the target's sources moved, this section is missing and the tap silently records digital silence — see `.issues/rca-002`.

- [ ] **Step 2: Verify the app bundle still assembles**

```bash
.build/release/quill install --app --to /tmp/quill-split-check.app
/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' /tmp/quill-split-check.app/Contents/Info.plist
codesign -dv /tmp/quill-split-check.app 2>&1 | grep -E 'Identifier|Signature'
rm -rf /tmp/quill-split-check.app
```

Expected: the bundle builds, the usage-description key is present, and the signature identifier is `com.digimata.quill`.

- [ ] **Step 3: Verify the launch-context check still works**

```bash
.build/release/quill doctor 2>&1 | grep 'system audio'
```

Expected, when run from a terminal: the failing launch-context message naming the terminal application. This proves `launchContext()` and its private-SPI call still function across the module boundary.

- [ ] **Step 4: Record what could not be verified**

A real recording session needs a menu-bar click and cannot be checked from a script. State plainly in the commit message that capture itself was not exercised end-to-end, so the next person knows what is still owed. Do not claim otherwise.

- [ ] **Step 5: Document the products in `README.md`**

Add a short section under the existing "Stack" heading. Explain what a consumer gets, and why the split exists — that transcription is derivable from the recorded files and therefore belongs downstream of capture:

```markdown
## Using quill as a library

quill exposes two library products:

| Product | Contents |
|---|---|
| `QuillCapture` | recording, config, the launch-context check — no FluidAudio |
| `QuillTranscribe` | transcription engines and the coordinator — depends on `QuillCapture` |

They are split because `transcript.json` is derived entirely from the recorded
`.caf` files after the fact. Which transcription engine to use, and whether to
download ~600 MB of model weights at all, are properties of the machine and the
user rather than of the act of recording — so a consumer can link `QuillCapture`
alone and decide transcription for itself.
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: document the library products

Verified unchanged: doctor's report, the embedded __info_plist section,
app bundle assembly, and the launch-context check. NOT verified: a real
recording, which needs a menu-bar click."
```

---

## Verification

**Automated:** none — this repo has no test target and this plan does not add one. Verification is the build plus the observable-behaviour checks in each task.

**Manual, and still owed after this plan:** a real recording through the menu bar, confirming both tracks capture and transcription still runs. That exercises the moved code paths that no script here can reach. It should happen before quire starts depending on these products.

## Follow-up, not in this plan

- quire's side of the spec: linking `QuillCapture`, owning the menu bar, the session lifecycle. Its own plan, written after this one lands.
- The public surface will need pruning once quire exists — this plan makes public only what the executable already touched, which may be more or less than quire needs.
