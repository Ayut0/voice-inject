# Repository Guidelines

## Project Structure & Module Organization
- `cmd/voice-inject/main.go` is the Go CLI entrypoint, with `daemon` (background hotkey listener) and `inject` (stdin-to-paste debug tool) subcommands.
- `internal/` holds the daemon's packages, following a state-machine design (`idle → recording → transcribing → injecting → idle`): `daemon` (hotkey + state machine), `record` (CoreAudio capture), `transcribe` (Whisper integration), `inject` (clipboard + paste via osascript), `postprocess` (text validation/normalization), `ipc` (daemon↔app protocol/bus/server), `config`, `state`, `logging`, `commands`.
- `app/` is a SwiftUI macOS app (Sources/, Tests/) that wraps the daemon in a window (status banner, Settings, History tab). `app/make-app.sh` builds the Go daemon and the Swift app and bundles them into `VoiceInject.app`.
- `docs/` contains planning and design notes.

## Build, Test, and Development Commands
- `go build ./cmd/voice-inject`: Build the CLI binary.
- `go run ./cmd/voice-inject`: Run directly.
- `go build ./...`: Compile all Go packages (syntax check).
- `go fmt ./...`: Format all Go files (run before committing).
- `go test ./...`: Run all Go tests; `go test ./internal/foo/` for a single package.
- `swift build` / `swift test` (from `app/`): Build/test the SwiftUI app; requires Xcode 15+ or the Swift 5.10+ toolchain, macOS 14+.

## Coding Style & Naming Conventions
- Go 1.22 module (`go.mod`): keep code compatible with Go 1.22.
- Formatting: use `gofmt` (`go fmt ./...`) before committing.
- Naming: follow Go conventions (MixedCaps for exported identifiers, lowerCamel for unexported, short receiver names).

## Testing Guidelines
- Go: standard `testing` package, table-driven tests, files named `*_test.go` next to the source (e.g., `internal/config/store_test.go`).
- Swift: XCTest-style tests under `app/Tests/VoiceInjectTests/`, one file per unit (e.g., `HUDStateTests.swift`).

## Commit & Pull Request Guidelines
- Commit subjects are clear and imperative (e.g., "Add manual start/stop daemon control").
- Branches follow `<prefix>/issue-<number>-<short-description>` (prefixes: `feat/`, `bugfix/`, `fix/`, `doc/`, `chore/`), and PRs link the corresponding GitHub issue.
- PRs should include a brief summary, the commands run (if any), and any relevant screenshots or terminal output.

## Configuration & Environment Notes
- macOS only: relies on `pbcopy`, `osascript`, System Events, and Accessibility/Microphone permissions; call out OS-specific behavior in PRs.
- Runtime deps: `ffmpeg` (audio recording) and `whisper.cpp` (local speech-to-text via a downloaded `ggml-*.bin` model).
- No network calls — all transcription happens locally.
