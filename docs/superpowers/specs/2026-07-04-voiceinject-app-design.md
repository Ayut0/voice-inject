# VoiceInject.app — Native UI Companion for voice-inject

**Date:** 2026-07-04
**Status:** Approved design, pending implementation plan

## Problem

voice-inject works, but as a headless CLI daemon it has four usability gaps:

1. **No visual feedback** — while dictating, nothing on screen indicates recording, transcribing, or failure. Errors print to a terminal nobody is watching.
2. **Daemon lifecycle** — the user must open a terminal and run `voice-inject daemon`; it dies when the terminal closes.
3. **Setup and configuration** — dependencies (ffmpeg, whisper-cpp, model file, permissions) are installed by hand; configuration is hardcoded in `config.Default()` with only a `-lang` flag.
4. **Transcription quality management** — switching Whisper models requires knowing the filesystem path convention.

## Solution overview

Keep the Go daemon as the engine. Add a thin SwiftUI macOS app (regular Dock app, personal use, ad-hoc signing) that:

- spawns the Go daemon as a child process and owns its lifecycle,
- shows a floating HUD panel during recording/transcription,
- provides a main window with **Settings** and **History** tabs,
- (later) provides a first-run dependency checklist and model downloader.

The app and daemon communicate over a Unix domain socket using newline-delimited JSON (NDJSON). The CLI remains fully usable standalone; with no client connected, daemon behavior is unchanged.

Explicitly rejected alternatives: launchd-managed daemon with a client app (right architecture for wide distribution, overkill for personal use; the IPC protocol permits migrating later), and a full Swift rewrite (discards the working Go pipeline). A menu bar icon was considered and declined in favor of a regular Dock app.

## Architecture

```
┌─ VoiceInject.app (SwiftUI, app/ directory) ────────────┐
│  HUDPanel     SettingsView     HistoryView             │
│       ▲              │                                  │
│ events│              │commands (request/response)       │
│       └──── DaemonClient (sole protocol speaker) ──────│
└───────────────┬───────────────▲────────────────────────┘
     ~/Library/Application Support/voice-inject/daemon.sock
┌───────────────▼───────────────┴────────────────────────┐
│  voice-inject daemon (Go, child process)               │
│  hotkey → record → transcribe → postprocess → inject   │
│  + internal/ipc (socket server + event bus)            │
└─────────────────────────────────────────────────────────┘
```

### Go side (additive changes only)

- **New package `internal/ipc`**: Unix socket server at `~/Library/Application Support/voice-inject/daemon.sock` (mode 0600; stale socket file deleted and rebound at startup), NDJSON protocol types, and a small event bus. The daemon's state machine adds one `Publish` call per transition. With zero subscribers, events are dropped silently.
- **`internal/config` gains `Load()`/`Save()`**: JSON config file in the same Application Support directory. Daemon loads it at startup, falling back to `Default()` when absent.

### Swift side (new `app/` directory in this repo)

- **`VoiceInjectApp`** — Dock app. On launch: spawn `voice-inject daemon` as a child `Process`, connect to the socket (retry ~2 s), reconnect/respawn on failure.
- **`DaemonClient`** — the only class that speaks the socket protocol; exposes daemon state via `@Observable`. All UI depends on it alone.
- **`HUDPanel`** — non-activating floating `NSPanel` (never steals focus from the target app). Shown on `recording`, switches to spinner on `transcribing`, fades out on `idle`, flashes message ~2 s on `error`. v1 shows a pulse animation and elapsed-time bar (elapsed is computed app-side from the arrival of the `recording` event; the max comes from config — no timing events needed) — **no real waveform** (parsing ffmpeg `astats` output is deferred until the pulse feels insufficient).
- **`SettingsView`** — language, model picker, recording limits; reads/writes via `getConfig`/`setConfig`.
- **`HistoryView`** — transcript list (timestamp, text, copy button) persisted as a JSONL file owned by the Swift app, with an on/off privacy toggle. The daemon stays stateless (logs only).

### Lifecycle rules

- The daemon is spawned with a pipe on stdin and **exits on stdin EOF** — if the app crashes or force-quits, the orphaned daemon dies rather than keep listening to the hotkey.
- Launch-at-login (SMAppService) on the app covers the daemon automatically, since the app owns it.
- Quitting the app stops dictation — intended behavior under this architecture.

## Protocol

NDJSON over the Unix socket. Outer discriminator `type` separates message kinds; for events, `name` alone determines the full shape (single-key discriminated union — a decoder never needs a second field to know what it is holding).

**Events (daemon → app, pushed, no ack):**

```json
{"type":"event","name":"recording"}
{"type":"event","name":"transcribing"}
{"type":"event","name":"idle"}
{"type":"event","name":"transcript","data":{"text":"hello world","lang":"en","durationMs":2300}}
{"type":"event","name":"error","data":{"stage":"transcribe","message":"model file not found"}}
```

State events carry no payload. Swift maps events 1:1 onto an enum:

```swift
enum DaemonEvent {
    case recording, transcribing, idle
    case transcript(text: String, lang: String, durationMs: Int)
    case error(stage: String, message: String)
}
```

**Commands (app → daemon, request/response matched by `id`):**

```json
→ {"type":"cmd","id":1,"name":"getConfig"}
← {"type":"resp","id":1,"ok":true,"data":{"lang":"en","model":"…/ggml-base.bin","maxRecordMs":60000}}
→ {"type":"cmd","id":2,"name":"setConfig","data":{"lang":"ja"}}
← {"type":"resp","id":2,"ok":true}
```

v1 command set (deliberately minimal): `getConfig`, `setConfig`, `status` (returns `{"state":"idle","version":"…"}` — lets a reconnecting client resync without waiting for the next event), `shutdown`. Responses carry `id` because events interleave with responses on the same stream; "next reply wins" would mispair them. Failed commands return `{"type":"resp","id":N,"ok":false,"error":"message"}`.

`setConfig` applies live where safe (language, limits) and persists to the config file. Model path changes take effect on the next transcription — `transcribe` shells out to `whisper-cli` per run, so there is no loaded model to reload.

**Dictation round-trip:**

1. Hold Option+Space → `recording` event → HUD appears.
2. Release → `transcribing` → HUD spinner.
3. Whisper finishes → daemon validates and pastes as today → `transcript` + `idle` → HUD fades, History appends.
4. Any failure → `error` → HUD flashes the message instead of silently vanishing.

## Error handling

- **Daemon child exits unexpectedly** → app's `terminationHandler` fires; show a non-modal "Daemon stopped — Restart?" banner and auto-restart once. If it dies again within 10 s, stop retrying and surface the last stderr lines (no unbounded crash loop).
- **Stale socket** → daemon deletes and rebinds the socket path at startup; app retries connect ~2 s before declaring failure.
- **Startup pre-checks fail** (existing model-file and accessibility checks) → reported as `error` events to the connected client; routed to the Phase 5 checklist UI (plain alert until then). CLI-only behavior unchanged (prints to terminal).
- **Malformed socket line** → both sides skip the line and log; never disconnect over one bad line.
- **No client connected** → daemon behaves exactly as today.

## Phasing

| Phase | Deliverable | Pain addressed |
|-------|-------------|----------------|
| 1 | `internal/ipc` + config persistence in Go; acceptance-testable with `nc -U` | Foundation |
| 2 | Swift app skeleton: spawns daemon, live status, Settings tab | Lifecycle + configuration |
| 3 | Recording HUD (pulse, elapsed bar, spinner, error flash) | Visual feedback |
| 4 | History tab (JSONL, copy button, privacy toggle) | Rescue lost text |
| 5 | First-run checklist with fix buttons + in-app model downloader | Setup friction + model switching |

Each phase is independently shippable and leaves a working tool. Implementation plans are written per phase, starting with Phase 1.

## Testing

- **Go (table-driven, per project conventions):** protocol encode/decode round-trips; event bus publish/subscribe including the zero-subscriber path; config `Load`/`Save` round-trip and missing-file → defaults; server command dispatch over `net.Pipe`.
- **Integration without Swift:** run the daemon, drive the socket with `nc -U` — this is the Phase 1 acceptance test.
- **Swift:** unit tests for `DaemonClient` NDJSON parsing (canned input); manual testing for HUD and windows. UI snapshot testing is out of scope for a personal tool.

## Out of scope (v1)

- Real waveform / mic-level metering in the HUD
- launchd LaunchAgent installation
- Code signing for distribution, notarization, Homebrew packaging
- Custom hotkey configuration (stays Option+Space)
- Streaming/partial transcription results
