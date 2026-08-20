---
title: "System-audio tap records digital silence when quill is launched from a terminal"
date: 2026-08-20
status: fixed
affects: "system audio capture and me/them speaker attribution"
---

## Context

Quill captures the far side of a meeting with a Core Audio process tap
(`AudioHardwareCreateProcessTap` + a private aggregate device), writing
`system.caf`. `TranscriptionCoordinator` tags `mic.caf` → `me` and
`system.caf` → `them`; that mapping is the entirety of quill's diarization
story.

The system-audio tap is gated by the TCC service `kTCCServiceAudioCapture`.
Quill ships no `.app` bundle, so `Package.swift` embeds an `Info.plist`
carrying `NSAudioCaptureUsageDescription` into the binary via
`-sectcreate __TEXT __info_plist`.

## Problem statement

Session `~/Recordings/2026.08.19-2030` (a real 23-minute meeting) produced a
transcript in which all 428 segments are tagged `me`. The far-side participants
appear in the transcript only because they came out of the laptop speakers and
back into the microphone.

`system.caf` is not quiet — it is literally zero:

```
decoded system.caf: samples 132,928,512   maxabs 0   nonzero 0
afinfo:             bit rate 2250 bps, maximum packet size 6 bytes
```

2250 bps with 6-byte packets is AAC's constant-silence floor. The file spans
the full 1384 s and is correctly clocked, so the aggregate device and IO proc
were running normally — they were simply handed zero-filled buffers.

Nothing surfaced the failure. `AudioHardwareCreateProcessTap` returned `noErr`,
the IO proc ran for the entire meeting, no error was logged, and
`Doctor.checkSystemAudio()` explicitly declines to check
("state unknowable until first use"). The loss was discovered a day later.

## RCA

TCC attributes a permission request to the **responsible process**, not to the
process making the call. Quill was launched from Ghostty, so the terminal
became the responsible process. From the unified log at the moment recording
started:

```
20:30:58.296 tccd AUTHREQ_CTX: service=kTCCServiceAudioCapture, preflight=no
20:30:58.302 tccd AUTHREQ_PROMPTING: service=kTCCServiceAudioCapture,
             subject=Sub:{com.mitchellh.ghostty}
             Resp:{identifier=com.mitchellh.ghostty,
                   binary_path=/Applications/Ghostty.app/Contents/MacOS/ghostty}
20:30:58.303 tccd Refusing authorization request for service
             kTCCServiceAudioCapture and subject Sub:{com.mitchellh.ghostty}
             without NSAudioCaptureUsageDescription key
20:30:58.303 tccd AUTHREQ_RESULT: authValue=0, authReason=8
```

Ghostty's `Info.plist` has no `NSAudioCaptureUsageDescription`, so tccd refused
to even display a prompt and denied outright (`authValue=0`). Quill's own
embedded plist was never consulted, because quill was never the subject.

Core Audio's response to an unauthorized tap is to deliver silence, not an
error. That converts a permission denial into an undetectable data-loss bug.

Note `kTCCServiceScreenCapture` returned `authValue=1` (undetermined) in the
same window — the two services are independent, and having Screen Recording
granted says nothing about audio capture.

## Verification

Root cause and fix path were confirmed empirically on 2026-08-20. The same
installed binary (`/usr/local/bin/quill`, unmodified) was started under launchd
instead of the terminal:

```sh
launchctl submit -l com.digimata.quill.test -- /usr/local/bin/quill run --out <dir>
# → PID 41692, PPID 1
```

tccd at the moment recording started:

```
11:08:45.779 AUTHREQ_PROMPTING: service=kTCCServiceAudioCapture,
             subject=Sub:{/usr/local/bin/quill}
             Resp:{identifier=quill, binary_path=/usr/local/bin/quill}
11:08:47.418 AUTHREQ_RESULT: authValue=2, authReason=2      ← allowed
```

No "Refusing ... without NSAudioCaptureUsageDescription". The prompt appeared
with quill itself as the subject and was granted.

Resulting tracks, with a synthesized speech probe played during the session:

```
SYSTEM TRACK: samples 8,884,224  maxabs 25358  nonzero 23.4%
MIC TRACK:    samples 4,339,200  maxabs 32768  nonzero 99.5%
```

```
**[0:00] them:** This is the system audio probe.
**[0:02] them:** If you can read the sentence in the them track, the process
                 tap is capturing correctly, repeating, system audio probe,
                 them track, tap is working.
```

**Conclusion: the embedded `__TEXT,__info_plist` does satisfy TCC.** No `.app`
bundle is required. The requirement is that quill be its own responsible
process.

Stated precisely, because the narrower phrasing ("don't launch from a
terminal") misreads the mechanism: Ghostty was not denied for being a
terminal. It was denied for being a responsible process whose bundle lacks
`NSAudioCaptureUsageDescription`. Any launcher that stays quill's parent
inherits that role and reproduces this bug — **Raycast included**, since
`Raycast.app` almost certainly lacks the key. Spotlight cannot launch a bare
Mach-O at all, so "launch from Spotlight" implies shipping an `.app` bundle.

**Resolved (2026-08-20):** Raycast reproduces the bug. Checked directly:

```
Raycast.app   NSAudioCaptureUsageDescription: ABSENT
Ghostty.app   NSAudioCaptureUsageDescription: ABSENT
```

A Raycast script command spawns quill as Raycast's child, making
`Raycast.app` the responsible process — and it lacks the key, so tccd refuses
to prompt exactly as it did for Ghostty. Launching quill from Raycast is the
same bug.

Consequences for the Spotlight/Raycast launch path: either ship a wrapper
`.app` that declares `NSAudioCaptureUsageDescription` (it then becomes a valid
responsible process, and quill-as-child inherits the grant), or have the
launcher route through launchd
(`launchctl kickstart -k gui/$UID/com.digimata.quill`) so launchd stays the
parent. Spawning the bare binary from any app is not an option.

## Defects to fix

Ordered by value. The silence guard comes first because it is the only
cause-agnostic one: it catches a denied tap, a route change, or a future macOS
regression alike. The others close today's specific cause.

1. **Silent failure.** A denied tap is indistinguishable from a quiet meeting.
   The IO proc should accumulate peak amplitude and warn (menu bar +
   notification) if the system track is still silent after ~30 s of recording.

   Check for **exact digital zero** (`peak == 0`), not a quietness threshold.
   The evidence argues for it: this file measured `maxabs 0`, not `maxabs 40`.
   A threshold false-positives on genuinely silent stretches of a real meeting,
   whereas a running IO proc that has delivered nothing but zeros for 30 s has
   no legitimate cause.

2. **Launch context.** Running `quill` directly from a shell silently poisons
   system-audio capture. README's "Run it (`quill` in a terminal...)" is
   actively wrong for the tap. The correct fix depends on the open question
   above.

3. **`doctor` punts.** The check is not "is the responsible process launchd"
   but "is the responsible process quill itself" — that is the axis TCC
   actually keys on. Reading one's own responsible pid is private SPI
   (`responsibility_get_pid_responsible_for_pid`), so `DoctorReport
   .launchContext()` approximates it: walk the ancestor chain for the nearest
   process inside an `.app` bundle and read that bundle's
   `NSAudioCaptureUsageDescription`. Reaching launchd first means quill is its
   own responsible process. This is deterministic, side-effect free, predicts
   the denial *before* the meeting, and generalises — it answers the question
   for any launcher (Raycast, a wrapper app) without a manual experiment.

## Out of scope (separate limitation, same complaint)

The reporting session had two people speaking into the one laptop microphone.
Even with the tap working perfectly, both land on `mic.caf` and both are tagged
`me`. Mic-vs-system attribution structurally cannot split co-located speakers;
that needs a diarization model. FluidAudio (already a dependency) vendors a
`Diarizer` module.

## Fix (2026-08-20)

All three defects addressed and verified against the live bug.

**1. Silence guard** — `SystemAudioRecorder` scans each tap buffer for a
non-zero sample (`vDSP_maxmgv` over the raw `AudioBufferList`; the tap format
is Float32 *interleaved*, so `floatChannelData` would have been wrong) and
latches `hasSignal`. `AppController.checkSystemTrack` warns once at 30 s —
menu bar, stderr, notification. `start()` now also reports
`system: tap=<format> silenceGuard=<bool>`, because the scan reads raw floats
and a non-float tap format would otherwise disable the guard silently — the
same failure class this whole issue is about.

**2. Launch context** — README no longer instructs a terminal launch. `quill`
refuses to start when the check fails, rather than record half a meeting.

Refuse-to-start was chosen deliberately for the system-audio case, but note it
widens the blast radius of the pre-existing `checkMicrophone()` `.fail` path:
every `swift build` changes the adhoc cdhash and drops both grants, and a user
who denies the microphone prompt once makes `quill` unlaunchable — the prompt
only fires from inside a recording that can no longer start. Recovery is
System Settings, or `tccutil reset Microphone`.

Additionally, the live check only runs from the elapsed-time ticker, so a
session shorter than the 30 s grace never reached it, and `stopSession()`
cleared the menu warning at the exact moment the user walks away. Stop now
re-checks the track regardless of duration and states the outcome as a fact
("last session captured no system audio") rather than a diagnosis — a
genuinely silent short session is indistinguishable from a denied tap.

**3. `doctor`** — `DoctorReport.launchContext()` reports the responsible
process and whether its bundle declares `NSAudioCaptureUsageDescription`.

The ancestry-walk approach drafted first was **wrong** and worth recording:
responsibility is assigned at spawn and survives reparenting, so under a
terminal multiplexer the ancestor chain reaches launchd through bare binaries
(`quill ← zsh ← claude ← fish ← herdr ← launchd`) with no `.app` in it, while
TCC still holds Ghostty responsible. It reported "fine" for a launch that was
in fact denied — a false negative in exactly the case the check exists for.
Replaced with `responsibility_get_pid_responsible_for_pid` via dlsym, which
returns nil-and-unknown rather than a false ok if the SPI ever disappears.

### Verification

Same binary, same probe audio playing throughout, only the launch path differs:

| | terminal child | under launchd |
|---|---|---|
| tccd | `Refusing ... Sub:{com.mitchellh.ghostty}` | `AUTHREQ_PROMPTING Sub:{/usr/local/bin/quill}` → `authValue=2` |
| guard | **fired** at 30 s | silent (no false positive) |
| `system.caf` | `maxabs 0` / 8,336,384 samples | `maxabs 25350` |
| `mic.caf` | `maxabs 8912` | `maxabs 20320` |

`doctor` in both contexts:

```
✗ system audio: launched by Ghostty, which does not declare
  NSAudioCaptureUsageDescription — macOS will deny the tap without
  prompting, and the system track will be silent          (exit 1)

! system audio: grant state unknowable until first use — will prompt
  on first recording                                       (under launchd)
```

Note it names Ghostty correctly despite Ghostty being nowhere in the ancestor
chain — the SPI sees what the heuristic could not.

## Follow-up: how `.app` bundles affect attribution (2026-08-20)

Measured with a throwaway bundle and a probe calling
`responsibility_get_pid_responsible_for_pid` directly, because the plan to make
the Spotlight/Raycast launch path a `.app` rests on assumptions worth checking.

| launch context | responsible process |
|---|---|
| bare binary from a shell | **Ghostty** (pid 1022) — the terminal, as tccd reported |
| under launchd | itself |
| spawned by a `.app` whose main executable is a **compiled binary** | **the `.app`** |
| spawned by a `.app` whose main executable is a **shell script** | **itself** |

Two consequences.

**The wrapper-app design works — as far as measured.** A compiled launcher
inside a `.app` makes the bundle the responsible process, so TCC reads *that
bundle's* `Info.plist` rather than the child's.

**Confirmed by measurement, 2026-08-20.** `quill install --app` builds an
ad-hoc-signed bundle; launched with `open`, the tap prompt is attributed to the
bundle identifier and granted:

```
11:58:41 AUTHREQ_PROMPTING: service=kTCCServiceAudioCapture,
         subject=Sub:{com.digimata.quill}
         Resp:{identifier=com.digimata.quill,
               binary_path=.../quill.app/Contents/MacOS/quill}
11:58:43 AUTHREQ_RESULT: authValue=2, authReason=2          ← granted
```

Recording through the bundle produced `system.caf maxabs 25346` and a
transcript containing 9 `them` segments — the thing missing from the meeting
that opened this issue. LaunchServices starts bundles via launchd (PPID 1) and
passes no `-psn_*` argument on macOS 15, so ArgumentParser needs no shim. Whether it should anyway, for launchability,
is a separate product decision (quill's README, `Install.swift`, and
`MenuBarController` all currently commit to "single binary, no app bundle").

**Shell-script launchers are a trap.** When the bundle's main executable is a
script, the shell disclaims responsibility and the child becomes its own
responsible process — silently changing which `Info.plist` TCC consults, from
the bundle's to the child's. quill happens to survive this (its embedded
`__TEXT,__info_plist` carries the key), but any launcher written as a shell
script gets attribution semantics different from a compiled one, with no
diagnostic to say so.

Note for distribution: the `.app` must be Developer ID signed and notarized, or
Gatekeeper quarantines it for anyone who did not build it locally — the usual
"damaged and can't be opened". Adhoc signing is enough only on the build
machine.

### Bug found in the fix itself

`launchContext()` originally collapsed "SPI unavailable" into
`.responsibleForSelf`, i.e. reported a launch context it could not verify as
fine — the exact false negative the check exists to prevent, and directly
contrary to the comment above it. Now a distinct `.unknown` case that warns.

## Follow-up: the mic track had the same hole (2026-08-20)

`MicRecorder` already had a liveness check — `livenessPeak`, the rca-001 fix —
but only on `installVoiceTap`. Since `mic_voice_processing` defaults to
**off**, the default `installRawTap` path had no silence detection at all: a
muted or wrong input device would record a silent mic track with nothing
surfacing it, the same class of failure this issue is about, on the track
carrying the user's own voice.

Added `MicRecorder.hasSignal`, mirroring `SystemAudioRecorder.hasSignal` and
latched from both tap paths. The narrower `livenessPeak` check is left alone —
it covers the first second of the voice route specifically because that route
has a recovery (restart raw), whereas the latch answers the whole-session
"is this track usable at all" question, which has no recovery. The 30 s guard
and the stop-time check now cover both tracks.

**Re-verified after the refactor (2026-08-20), through `quill.app`.** Recording
with nothing playing, so the tap is authorized but the track is genuinely
silent:

```
session started 12:03:35
notification fired 12:04:06.6      ← +31.6 s, the 30 s guard
system.caf grew at 272 B/s         ← AAC's constant-silence floor
SYSTEM maxabs 0    MIC maxabs 14508
```

Exactly one notification fired, so the mic branch correctly did *not*
false-positive on room noise while the system branch did fire. The mic-silent
path itself is still unverified — it needs a muted or absent input device.

### A footgun found in `install --app`

The first attempt at this test proved nothing: `writeAppBundle` called
`resolveBinaryPath()`, which prefers `/usr/local/bin/quill`, so
`.build/release/quill install --app` silently bundled a stale binary predating
the guard. `--app` now bundles the *running* executable via
`proc_pidpath(getpid())` and prints a `from:` line naming it.
