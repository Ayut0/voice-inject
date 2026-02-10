# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**voice-inject** is a macOS-native CLI voice input daemon written in Go 1.22. It captures audio via a hotkey (Option+Space), transcribes locally using Whisper (whisper.cpp), and pastes the result via clipboard (pbcopy + osascript). No GUI, no network calls.

## Build & Run Commands

```bash
go build ./cmd/voice-inject       # Build the CLI binary
go run ./cmd/voice-inject          # Run directly
go build ./...                     # Compile all packages (syntax check)
go fmt ./...                       # Format all Go files (run before committing)
go test ./...                      # Run all tests
go test ./internal/foo/            # Run tests for a single package
```

## Architecture

The CLI entry point is `cmd/voice-inject/main.go` with two subcommands: `daemon` (background hotkey listener) and `inject` (stdin-to-paste debug tool).

Internal packages live under `internal/` following a state-machine design:

```
[idle] ──(Option+Space hold)──> [recording] ──(release/silence)──> [transcribing] ──(Whisper)──> [injecting] ──(pbcopy+⌘V)──> [idle]
```

Key packages: `daemon` (hotkey + state machine), `record` (audio capture via CoreAudio), `transcribe` (Whisper integration), `inject` (clipboard + paste via osascript), `postprocess` (text validation/normalization), `config`, `state`, `logging`, `commands`.

## Platform Constraints

- **macOS only**: relies on `pbcopy`, `osascript`, System Events, and Accessibility permissions
- Audio: WAV format, 700ms min / 60s max duration, 4s silence timeout
- Post-processing safety: rejects empty, <3 char, >5000 char, or abnormal-symbol-ratio text

## Conventions

- Go 1.22 compatibility required
- Standard `testing` package with table-driven tests; test files as `*_test.go` next to source
- MixedCaps for exported, lowerCamel for unexported identifiers
- Imperative commit subjects (e.g., "Add CLI skeleton")
