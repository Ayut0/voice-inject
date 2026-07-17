# voice-inject

A macOS-native CLI voice input daemon written in Go. Hold a hotkey, speak, and your words are transcribed locally and pasted into the active application. No GUI, no cloud APIs.

## How It Works

```
Hold Option+Space → Speak → Release → Text appears in your app
```

voice-inject captures audio from your microphone, transcribes it locally using [whisper.cpp](https://github.com/ggerganov/whisper.cpp), and injects the result into the currently focused application via the clipboard.

## Prerequisites

- **macOS** (relies on macOS-native APIs)
- **Go 1.22+**
- **ffmpeg** (audio recording)
- **whisper.cpp** (local speech-to-text)

## Installation

### 1. Install system dependencies

```bash
brew install ffmpeg whisper-cpp
```

### 2. Download a Whisper model

```bash
mkdir -p ~/.local/share/whisper-cpp/models

# Download the base model (~142 MB) - recommended for most users
curl -L -o ~/.local/share/whisper-cpp/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

Other available models:

| Model | Size | Notes |
|-------|------|-------|
| `ggml-tiny.bin` | 75 MiB | Fastest, least accurate |
| `ggml-base.bin` | 142 MiB | Good balance (recommended) |
| `ggml-small.bin` | 466 MiB | More accurate, slower |
| `ggml-medium.bin` | 1.5 GiB | High accuracy |
| `ggml-large-v3-turbo.bin` | 1.5 GiB | Best accuracy/speed ratio |

Models with an `.en` suffix (e.g., `ggml-base.en.bin`) are English-only and slightly more accurate for English.

### 3. Build voice-inject

```bash
git clone https://github.com/Ayut0/voice-inject.git
cd voice-inject
go build ./cmd/voice-inject
```

### 4. Grant Accessibility permission

voice-inject uses `osascript` to simulate a Cmd+V keystroke. macOS requires Accessibility permission for this.

**System Settings > Privacy & Security > Accessibility** — add your terminal emulator (e.g., Terminal, iTerm2, Alacritty).

### 5. Grant Microphone permission

macOS requires Microphone permission for audio capture.

**System Settings > Privacy & Security > Microphone** — enable access for your terminal emulator.

### 6. (Optional) Install system-wide

Move the binary to a directory in your PATH to run `voice-inject` from anywhere:

```bash
mv voice-inject /usr/local/bin/voice-inject
```

## Usage

### Start the daemon

```bash
./voice-inject daemon
```

Once running:

1. **Hold Option+Space** to start recording
2. **Speak** into your microphone
3. **Release Option+Space** to stop recording
4. The transcribed text is pasted into the active application

Press **Ctrl+C** to stop the daemon.

### Language selection

Use the `-lang` flag to set the transcription language (default: `en`):

| Flag | Language |
|------|----------|
| `en` | English (default) |
| `ja` | Japanese |

```bash
./voice-inject daemon -lang ja
```

### Run in the background

To keep the daemon running in the background:

```bash
./voice-inject daemon &
```

To stop it:

```bash
kill %1
```

### Debug: inject text from stdin

The `inject` subcommand reads text from stdin and pastes it, useful for testing the paste mechanism:

```bash
echo "hello world" | ./voice-inject inject
```

## macOS App (GUI)

A SwiftUI app wraps the daemon in a window (status banner, Settings, and a transcript History tab) so you don't have to run `./voice-inject daemon` from a terminal.

### Prerequisites

- Everything under [Prerequisites](#prerequisites) above (the app bundles and launches the same Go daemon)
- **Xcode 15+** or the **Swift 5.10+ command-line toolchain** (`swift build` must work — macOS 14+ required)

### Build and launch

```bash
cd app
./make-app.sh
open VoiceInject.app
```

`make-app.sh` builds the Go daemon and the Swift app, bundles them into `VoiceInject.app` (with the daemon under `Contents/Resources/`), and ad-hoc signs the result. Re-run it any time you pull new changes.

### Permissions

Same Accessibility and Microphone requirements as the CLI (see [steps 4](#4-grant-accessibility-permission) and [5](#5-grant-microphone-permission) above) — but grant them to **VoiceInject.app itself** in System Settings, not your terminal, since the app launches and owns the daemon process.

### One instance at a time

The app's managed daemon and the standalone CLI daemon (`./voice-inject daemon`) both bind the same fixed socket at `~/Library/Application Support/voice-inject/daemon.sock`. Don't run both at once — quit whichever is running (⌘Q on the app window, or Ctrl+C for the CLI) before starting the other.

## Recording Limits

| Parameter | Value |
|-----------|-------|
| Minimum duration | 700 ms |
| Maximum duration | 60 s |
| Silence auto-stop | 4 s |
| Min text length | 3 characters |
| Max text length | 5,000 characters |

## Architecture

```
[idle] → (Option+Space hold) → [recording] → (release / silence) → [transcribing] → (Whisper) → [injecting] → (pbcopy + Cmd+V) → [idle]
```

The project follows a state-machine design with internal packages:

```
cmd/voice-inject/       CLI entry point
internal/
  commands/             Command handlers (daemon, inject)
  config/               Configuration defaults
  daemon/               Hotkey listener + state machine
  record/               Audio capture via ffmpeg
  transcribe/           Speech-to-text via whisper-cli
  inject/               Clipboard paste (pbcopy + osascript)
  postprocess/          Text validation and normalization
  state/                State machine definitions
  logging/              Structured logging
```

## Troubleshooting

**"Is Accessibility enabled?"** — Grant Accessibility permission to your terminal in System Settings > Privacy & Security > Accessibility.

**No audio captured** — Make sure your microphone is working, `ffmpeg` is installed (`brew install ffmpeg`), and your terminal has Microphone permission in System Settings > Privacy & Security > Microphone.

**Transcription fails** — Verify the Whisper model exists at `~/.local/share/whisper-cpp/models/ggml-base.bin` and `whisper-cpp` is installed (`brew install whisper-cpp`).

## License

MIT
