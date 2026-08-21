# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --app              # ~/Applications/quill.app — see below
```

**Launch quill from the app bundle, not from a terminal.** macOS attributes the
system-audio permission to whichever process is *responsible* for quill, and
refuses to even show the prompt unless that process declares
`NSAudioCaptureUsageDescription`. Terminal emulators don't, and neither does
Raycast — so a shell-launched quill is denied silently, and an unauthorized tap
yields digital silence rather than an error. That means a whole meeting recorded
with an empty `them` track and nothing to tell you.

Inside a bundle, TCC reads the bundle's own Info.plist, so quill holds its own
grant no matter what starts it — Spotlight, Raycast, Dock, login item. Running
under launchd works too (`quill install --launch-at-login`), since launchd
makes quill its own responsible process. A bare terminal launch does not, and
`quill` refuses to start rather than record half a meeting. `quill doctor` tells
you which case you're in.

The bundle is ad-hoc signed, which is enough to run on the machine that built
it. Handing it to anyone else needs Developer ID signing and notarization, or
Gatekeeper will quarantine it.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** — launch `quill.app` (Spotlight, Raycast, Dock), or install the
   LaunchAgent. A bare terminal launch is refused; see Install above.
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v2**
(English) via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Core ML port — roughly 20 seconds per hour of audio on Apple Silicon. Models
(~600 MB) download once on first transcription; `quill doctor` tells you
whether they're already cached so you're never downloading after an important
meeting.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (launchd only; ^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --app          # build ~/Applications/quill.app (--to <path> to override)
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — an SPM package: two library targets (`QuillCapture`,
  `QuillTranscribe`) plus the `quill` executable target that links both
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

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

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If the system track comes out silent, run `quill doctor` first — the usual
  cause is launch context, not the permission toggle. Failing that, check
  System Settings → Privacy & Security → Screen & System Audio Recording.
- While recording, quill watches the system track and warns in the menu bar
  (and by notification) if it is still digitally silent after 30 seconds.
- `me` vs `them` is mic-vs-system, not speaker identification. Two people
  sharing your laptop's microphone both come out as `me`.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
- The binary is adhoc-signed, so every `swift build` (and every
  `install --app`, which re-signs) changes its cdhash and drops the granted
  permissions. Expect to approve the prompt again after rebuilding. A stable
  Developer ID signature would make grants survive updates.
- `install --app` bundles the *running* binary, not `/usr/local/bin/quill` —
  so `swift build -c release && .build/release/quill install --app` ships what
  you just built. The printed `from:` line says which binary went in.
