# IPC Layer + Config Persistence (Issue #28) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Unix-socket NDJSON control/event channel (`internal/ipc`) and JSON config persistence to the voice-inject daemon, verifiable end-to-end with `nc -U` — no Swift involved.

**Architecture:** A small event bus decouples the daemon state machine from connected clients: the daemon publishes events at each state transition; an `ipc.Server` fans them out to all connected Unix-socket clients and dispatches NDJSON commands (`getConfig`/`setConfig`/`status`/`shutdown`) to a handler closure living in the daemon package. Config gains a wire/JSON representation shared by the config file and the IPC payloads, plus a mutex-guarded `Store` so `setConfig` can apply live.

**Tech Stack:** Go 1.22 standard library only (`net`, `encoding/json`, `sync`, `bufio`). No new dependencies.

## Global Constraints

- Go 1.22 compatibility (from CLAUDE.md)
- Table-driven tests with the standard `testing` package; `*_test.go` next to source (from CLAUDE.md)
- MixedCaps exported / lowerCamel unexported identifiers (from CLAUDE.md)
- Socket path: `~/Library/Application Support/voice-inject/daemon.sock`, mode 0600 (spec)
- Config file: `~/Library/Application Support/voice-inject/config.json` (spec)
- Event shapes exactly as in the spec: `{"type":"event","name":"recording"}` etc.; single-key discriminated union on `name`; state events carry no payload (spec)
- Responses matched to commands by `id`; failed commands return `{"type":"resp","id":N,"ok":false,"error":"message"}` (spec)
- Malformed socket lines are skipped and logged, never a disconnect (spec)
- Zero clients connected → daemon behavior identical to today (spec)
- Startup pre-checks keep today's fail-fast behavior; converting them to error events is Phase 5 scope, not this issue
- Run `go fmt ./...` before every commit (from CLAUDE.md)
- Imperative commit subjects (from CLAUDE.md)

---

### Task 1: Protocol types and encoding (`internal/ipc/protocol.go`)

**Files:**
- Create: `internal/ipc/protocol.go`
- Test: `internal/ipc/protocol_test.go`

**Interfaces:**
- Consumes: nothing (leaf package file)
- Produces (used by Tasks 2, 5, 6):
  - Constants `TypeEvent, TypeCmd, TypeResp`; `EventRecording, EventTranscribing, EventIdle, EventTranscript, EventError`; `CmdGetConfig, CmdSetConfig, CmdStatus, CmdShutdown`
  - `type Event struct { Type, Name string; Data any }` (JSON tags `type,name,data omitempty`)
  - `type Command struct { Type string; ID int64; Name string; Data json.RawMessage }`
  - `type Response struct { Type string; ID int64; OK bool; Data any; Error string }`
  - `func StateEvent(name string) Event`
  - `func TranscriptEvent(text, lang string, durationMs int64) Event`
  - `func ErrorEvent(stage, message string) Event`
  - `func OKResponse(id int64, data any) Response`
  - `func ErrResponse(id int64, msg string) Response`
  - `func EncodeLine(v any) ([]byte, error)` — JSON + trailing `\n`
  - `func DecodeCommand(line []byte) (Command, error)` — rejects `type != "cmd"` or empty `name`

- [ ] **Step 1: Write the failing test**

Create `internal/ipc/protocol_test.go`:

```go
package ipc

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestEncodeLineEventShapes(t *testing.T) {
	tests := []struct {
		name string
		ev   Event
		want string
	}{
		{"state event has no data key", StateEvent(EventRecording),
			`{"type":"event","name":"recording"}`},
		{"idle", StateEvent(EventIdle),
			`{"type":"event","name":"idle"}`},
		{"transcript", TranscriptEvent("hello world", "en", 2300),
			`{"type":"event","name":"transcript","data":{"text":"hello world","lang":"en","durationMs":2300}}`},
		{"error", ErrorEvent("transcribe", "model file not found"),
			`{"type":"event","name":"error","data":{"stage":"transcribe","message":"model file not found"}}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := EncodeLine(tt.ev)
			if err != nil {
				t.Fatalf("EncodeLine: %v", err)
			}
			if string(got) != tt.want+"\n" {
				t.Errorf("got %q, want %q", got, tt.want+"\n")
			}
		})
	}
}

func TestDecodeCommand(t *testing.T) {
	tests := []struct {
		name    string
		line    string
		wantErr bool
		wantCmd string
		wantID  int64
	}{
		{"getConfig", `{"type":"cmd","id":1,"name":"getConfig"}`, false, CmdGetConfig, 1},
		{"setConfig with data", `{"type":"cmd","id":2,"name":"setConfig","data":{"lang":"ja"}}`, false, CmdSetConfig, 2},
		{"wrong type", `{"type":"event","name":"idle"}`, true, "", 0},
		{"missing name", `{"type":"cmd","id":3}`, true, "", 0},
		{"not json", `hello`, true, "", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cmd, err := DecodeCommand([]byte(tt.line))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if err != nil {
				return
			}
			if cmd.Name != tt.wantCmd || cmd.ID != tt.wantID {
				t.Errorf("got (%s,%d), want (%s,%d)", cmd.Name, cmd.ID, tt.wantCmd, tt.wantID)
			}
		})
	}
}

func TestResponseShapes(t *testing.T) {
	okLine, err := EncodeLine(OKResponse(1, map[string]string{"state": "idle"}))
	if err != nil {
		t.Fatalf("EncodeLine: %v", err)
	}
	if want := `{"type":"resp","id":1,"ok":true,"data":{"state":"idle"}}` + "\n"; string(okLine) != want {
		t.Errorf("ok resp: got %q want %q", okLine, want)
	}

	errLine, err := EncodeLine(ErrResponse(2, "unknown command"))
	if err != nil {
		t.Fatalf("EncodeLine: %v", err)
	}
	if !strings.Contains(string(errLine), `"ok":false`) || !strings.Contains(string(errLine), `"error":"unknown command"`) {
		t.Errorf("err resp missing fields: %q", errLine)
	}
	// error responses must not carry a data key
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(errLine, &raw); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, ok := raw["data"]; ok {
		t.Errorf("error response should omit data: %q", errLine)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ipc/`
Expected: FAIL — `no such file or directory` / undefined symbols (package doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `internal/ipc/protocol.go`:

```go
// Package ipc implements the daemon's Unix-socket control and event
// channel: newline-delimited JSON, one message per line.
package ipc

import (
	"encoding/json"
	"fmt"
)

// Outer message discriminator ("type" field).
const (
	TypeEvent = "event"
	TypeCmd   = "cmd"
	TypeResp  = "resp"
)

// Event names. For events, "name" alone determines the message shape.
const (
	EventRecording    = "recording"
	EventTranscribing = "transcribing"
	EventIdle         = "idle"
	EventTranscript   = "transcript"
	EventError        = "error"
)

// Command names.
const (
	CmdGetConfig = "getConfig"
	CmdSetConfig = "setConfig"
	CmdStatus    = "status"
	CmdShutdown  = "shutdown"
)

type Event struct {
	Type string `json:"type"`
	Name string `json:"name"`
	Data any    `json:"data,omitempty"`
}

type TranscriptData struct {
	Text       string `json:"text"`
	Lang       string `json:"lang"`
	DurationMs int64  `json:"durationMs"`
}

type ErrorData struct {
	Stage   string `json:"stage"`
	Message string `json:"message"`
}

func StateEvent(name string) Event {
	return Event{Type: TypeEvent, Name: name}
}

func TranscriptEvent(text, lang string, durationMs int64) Event {
	return Event{Type: TypeEvent, Name: EventTranscript, Data: TranscriptData{Text: text, Lang: lang, DurationMs: durationMs}}
}

func ErrorEvent(stage, message string) Event {
	return Event{Type: TypeEvent, Name: EventError, Data: ErrorData{Stage: stage, Message: message}}
}

type Command struct {
	Type string          `json:"type"`
	ID   int64           `json:"id"`
	Name string          `json:"name"`
	Data json.RawMessage `json:"data,omitempty"`
}

type Response struct {
	Type  string `json:"type"`
	ID    int64  `json:"id"`
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

func OKResponse(id int64, data any) Response {
	return Response{Type: TypeResp, ID: id, OK: true, Data: data}
}

func ErrResponse(id int64, msg string) Response {
	return Response{Type: TypeResp, ID: id, OK: false, Error: msg}
}

// EncodeLine marshals v as one NDJSON line (JSON + trailing newline).
func EncodeLine(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// DecodeCommand parses one line as a Command. It rejects lines whose
// type is not "cmd" or whose name is empty.
func DecodeCommand(line []byte) (Command, error) {
	var cmd Command
	if err := json.Unmarshal(line, &cmd); err != nil {
		return Command{}, fmt.Errorf("invalid json: %w", err)
	}
	if cmd.Type != TypeCmd {
		return Command{}, fmt.Errorf("expected type %q, got %q", TypeCmd, cmd.Type)
	}
	if cmd.Name == "" {
		return Command{}, fmt.Errorf("command has no name")
	}
	return cmd, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ipc/`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
go fmt ./internal/ipc/
git add internal/ipc/protocol.go internal/ipc/protocol_test.go
git commit -m "Add IPC protocol types and NDJSON encoding"
```

---

### Task 2: Event bus (`internal/ipc/bus.go`)

**Files:**
- Create: `internal/ipc/bus.go`
- Test: `internal/ipc/bus_test.go`

**Interfaces:**
- Consumes: `Event` from Task 1
- Produces (used by Tasks 5, 6):
  - `func NewBus() *Bus`
  - `func (b *Bus) Subscribe() (id int, ch <-chan Event)` — buffered channel, capacity 16
  - `func (b *Bus) Unsubscribe(id int)` — idempotent; closes the channel
  - `func (b *Bus) Publish(ev Event)` — never blocks; drops events for full subscriber buffers; no-op with zero subscribers

- [ ] **Step 1: Write the failing test**

Create `internal/ipc/bus_test.go`:

```go
package ipc

import "testing"

func TestBusPublishWithNoSubscribersDoesNotBlock(t *testing.T) {
	b := NewBus()
	// Must return immediately; a hang here fails via test timeout.
	b.Publish(StateEvent(EventIdle))
}

func TestBusDeliversToAllSubscribers(t *testing.T) {
	b := NewBus()
	_, ch1 := b.Subscribe()
	_, ch2 := b.Subscribe()

	b.Publish(StateEvent(EventRecording))

	for i, ch := range []<-chan Event{ch1, ch2} {
		ev := <-ch
		if ev.Name != EventRecording {
			t.Errorf("subscriber %d: got %q, want %q", i, ev.Name, EventRecording)
		}
	}
}

func TestBusUnsubscribeClosesChannel(t *testing.T) {
	b := NewBus()
	id, ch := b.Subscribe()
	b.Unsubscribe(id)
	if _, ok := <-ch; ok {
		t.Error("channel should be closed after Unsubscribe")
	}
	b.Unsubscribe(id) // idempotent: must not panic
}

func TestBusDropsWhenSubscriberBufferFull(t *testing.T) {
	b := NewBus()
	_, ch := b.Subscribe()
	// Fill past the buffer; Publish must never block.
	for i := 0; i < subscriberBuffer+10; i++ {
		b.Publish(StateEvent(EventIdle))
	}
	// Drain: we should get exactly subscriberBuffer events.
	got := 0
	for {
		select {
		case <-ch:
			got++
		default:
			if got != subscriberBuffer {
				t.Errorf("got %d buffered events, want %d", got, subscriberBuffer)
			}
			return
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ipc/`
Expected: FAIL — `undefined: NewBus`, `undefined: subscriberBuffer`

- [ ] **Step 3: Write the implementation**

Create `internal/ipc/bus.go`:

```go
package ipc

import "sync"

// subscriberBuffer is the per-subscriber event buffer. Publish drops
// events for subscribers whose buffer is full rather than blocking the
// daemon's state machine.
const subscriberBuffer = 16

// Bus fans events out to subscribers. Safe for concurrent use.
type Bus struct {
	mu   sync.Mutex
	next int
	subs map[int]chan Event
}

func NewBus() *Bus {
	return &Bus{subs: make(map[int]chan Event)}
}

func (b *Bus) Subscribe() (int, <-chan Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := b.next
	b.next++
	ch := make(chan Event, subscriberBuffer)
	b.subs[id] = ch
	return id, ch
}

func (b *Bus) Unsubscribe(id int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.subs[id]; ok {
		delete(b.subs, id)
		close(ch)
	}
}

// Publish never blocks: subscribers with a full buffer miss the event.
func (b *Bus) Publish(ev Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, ch := range b.subs {
		select {
		case ch <- ev:
		default:
		}
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ipc/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
go fmt ./internal/ipc/
git add internal/ipc/bus.go internal/ipc/bus_test.go
git commit -m "Add IPC event bus with non-blocking publish"
```

---

### Task 3: Config wire format, persistence, and patch (`internal/config/persist.go`)

**Files:**
- Create: `internal/config/persist.go`
- Test: `internal/config/persist_test.go`

**Interfaces:**
- Consumes: `Config`, `Default()`, `ValidLanguage`, `Language` from the existing `internal/config/config.go`
- Produces (used by Tasks 4, 6):
  - `type Wire struct` — JSON form of `Config`; durations as `…Ms int64`; field names exactly `lang, model, minRecordMs, maxRecordMs, silenceTimeoutMs, minTextLength, maxTextLength, camelCaseRule, maxSymbolRatio`
  - `func (c Config) ToWire() Wire`
  - `func (w Wire) ToConfig() Config`
  - `func (c Config) ApplyPatch(raw []byte) (Config, error)` — partial update; unknown fields ignored; invalid lang rejected
  - `func Dir() (string, error)` — `~/Library/Application Support/voice-inject`, created 0700
  - `func SocketPath() (string, error)` — `<Dir>/daemon.sock`
  - `func LoadFrom(path string) (Config, error)` — missing file → `Default()`, nil error
  - `func (c Config) SaveTo(path string) error` — writes indented JSON, mode 0600
  - `func Load() (Config, error)` / `func (c Config) Save() error` — wrappers over `<Dir>/config.json`

- [ ] **Step 1: Write the failing test**

Create `internal/config/persist_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")

	cfg := Default()
	cfg.DefaultLanguage = Japanese
	cfg.MaxRecordDuration = 30 * time.Second

	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo: %v", err)
	}
	got, err := LoadFrom(path)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if got != cfg {
		t.Errorf("round trip mismatch:\n got  %+v\n want %+v", got, cfg)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("file mode = %o, want 600", perm)
	}
}

func TestLoadFromMissingFileReturnsDefaults(t *testing.T) {
	got, err := LoadFrom(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatalf("LoadFrom missing file: %v", err)
	}
	if got != Default() {
		t.Errorf("got %+v, want Default()", got)
	}
}

func TestLoadFromCorruptFileReturnsError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFrom(path); err == nil {
		t.Error("want error for corrupt config file")
	}
}

func TestApplyPatch(t *testing.T) {
	tests := []struct {
		name    string
		patch   string
		wantErr bool
		check   func(t *testing.T, c Config)
	}{
		{"change lang", `{"lang":"ja"}`, false, func(t *testing.T, c Config) {
			if c.DefaultLanguage != Japanese {
				t.Errorf("lang = %q, want ja", c.DefaultLanguage)
			}
			if c.MaxTextLength != Default().MaxTextLength {
				t.Error("untouched field changed")
			}
		}},
		{"change max duration", `{"maxRecordMs":30000}`, false, func(t *testing.T, c Config) {
			if c.MaxRecordDuration != 30*time.Second {
				t.Errorf("MaxRecordDuration = %v, want 30s", c.MaxRecordDuration)
			}
		}},
		{"invalid lang rejected", `{"lang":"xx"}`, true, nil},
		{"invalid json rejected", `{`, true, nil},
		{"unknown fields ignored", `{"bogus":true}`, false, func(t *testing.T, c Config) {
			if c != Default() {
				t.Error("config changed by unknown field")
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Default().ApplyPatch([]byte(tt.patch))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.check != nil {
				tt.check(t, got)
			}
		})
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/config/`
Expected: FAIL — `undefined: SaveTo` etc.

- [ ] **Step 3: Write the implementation**

Create `internal/config/persist.go`:

```go
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// Wire is the JSON representation of Config, shared by the config file
// and the IPC getConfig/setConfig payloads. Durations are milliseconds.
type Wire struct {
	Lang             string  `json:"lang"`
	Model            string  `json:"model"`
	MinRecordMs      int64   `json:"minRecordMs"`
	MaxRecordMs      int64   `json:"maxRecordMs"`
	SilenceTimeoutMs int64   `json:"silenceTimeoutMs"`
	MinTextLength    int     `json:"minTextLength"`
	MaxTextLength    int     `json:"maxTextLength"`
	CamelCaseRule    bool    `json:"camelCaseRule"`
	MaxSymbolRatio   float64 `json:"maxSymbolRatio"`
}

func (c Config) ToWire() Wire {
	return Wire{
		Lang:             string(c.DefaultLanguage),
		Model:            c.WhisperModel,
		MinRecordMs:      c.MinRecordDuration.Milliseconds(),
		MaxRecordMs:      c.MaxRecordDuration.Milliseconds(),
		SilenceTimeoutMs: c.SilenceTimeout.Milliseconds(),
		MinTextLength:    c.MinTextLength,
		MaxTextLength:    c.MaxTextLength,
		CamelCaseRule:    c.CamelCaseRule,
		MaxSymbolRatio:   c.MaxSymbolRatio,
	}
}

func (w Wire) ToConfig() Config {
	return Config{
		DefaultLanguage:   Language(w.Lang),
		WhisperModel:      w.Model,
		MinRecordDuration: time.Duration(w.MinRecordMs) * time.Millisecond,
		MaxRecordDuration: time.Duration(w.MaxRecordMs) * time.Millisecond,
		SilenceTimeout:    time.Duration(w.SilenceTimeoutMs) * time.Millisecond,
		MinTextLength:     w.MinTextLength,
		MaxTextLength:     w.MaxTextLength,
		CamelCaseRule:     w.CamelCaseRule,
		MaxSymbolRatio:    w.MaxSymbolRatio,
	}
}

// ApplyPatch returns a copy of c with the non-null fields of the JSON
// patch applied. Unknown fields are ignored.
func (c Config) ApplyPatch(raw []byte) (Config, error) {
	var p struct {
		Lang             *string  `json:"lang"`
		Model            *string  `json:"model"`
		MinRecordMs      *int64   `json:"minRecordMs"`
		MaxRecordMs      *int64   `json:"maxRecordMs"`
		SilenceTimeoutMs *int64   `json:"silenceTimeoutMs"`
		MinTextLength    *int     `json:"minTextLength"`
		MaxTextLength    *int     `json:"maxTextLength"`
		CamelCaseRule    *bool    `json:"camelCaseRule"`
		MaxSymbolRatio   *float64 `json:"maxSymbolRatio"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return Config{}, fmt.Errorf("invalid patch: %w", err)
	}
	if p.Lang != nil {
		if !ValidLanguage(Language(*p.Lang)) {
			return Config{}, fmt.Errorf("unsupported language: %q", *p.Lang)
		}
		c.DefaultLanguage = Language(*p.Lang)
	}
	if p.Model != nil {
		c.WhisperModel = *p.Model
	}
	if p.MinRecordMs != nil {
		c.MinRecordDuration = time.Duration(*p.MinRecordMs) * time.Millisecond
	}
	if p.MaxRecordMs != nil {
		c.MaxRecordDuration = time.Duration(*p.MaxRecordMs) * time.Millisecond
	}
	if p.SilenceTimeoutMs != nil {
		c.SilenceTimeout = time.Duration(*p.SilenceTimeoutMs) * time.Millisecond
	}
	if p.MinTextLength != nil {
		c.MinTextLength = *p.MinTextLength
	}
	if p.MaxTextLength != nil {
		c.MaxTextLength = *p.MaxTextLength
	}
	if p.CamelCaseRule != nil {
		c.CamelCaseRule = *p.CamelCaseRule
	}
	if p.MaxSymbolRatio != nil {
		c.MaxSymbolRatio = *p.MaxSymbolRatio
	}
	return c, nil
}

// Dir returns the app's support directory, creating it if needed.
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "Application Support", "voice-inject")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// SocketPath returns the daemon's Unix socket path.
func SocketPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "daemon.sock"), nil
}

// LoadFrom reads a config file. A missing file is not an error: it
// returns Default().
func LoadFrom(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Default(), nil
	}
	if err != nil {
		return Config{}, err
	}
	var w Wire
	if err := json.Unmarshal(b, &w); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return w.ToConfig(), nil
}

// SaveTo writes the config as indented JSON, mode 0600.
func (c Config) SaveTo(path string) error {
	b, err := json.MarshalIndent(c.ToWire(), "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o600)
}

func configPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// Load reads the default config file location.
func Load() (Config, error) {
	path, err := configPath()
	if err != nil {
		return Config{}, err
	}
	return LoadFrom(path)
}

// Save writes to the default config file location.
func (c Config) Save() error {
	path, err := configPath()
	if err != nil {
		return err
	}
	return c.SaveTo(path)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/config/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
go fmt ./internal/config/
git add internal/config/persist.go internal/config/persist_test.go
git commit -m "Add config wire format, persistence, and patch support"
```

---

### Task 4: Thread-safe config store (`internal/config/store.go`)

**Files:**
- Create: `internal/config/store.go`
- Test: `internal/config/store_test.go`

**Interfaces:**
- Consumes: `Config` from `internal/config/config.go`
- Produces (used by Task 6):
  - `func NewStore(cfg Config) *Store`
  - `func (s *Store) Get() Config` — returns a copy
  - `func (s *Store) Set(cfg Config)`

- [ ] **Step 1: Write the failing test**

Create `internal/config/store_test.go`:

```go
package config

import (
	"sync"
	"testing"
)

func TestStoreGetSet(t *testing.T) {
	s := NewStore(Default())
	if got := s.Get(); got != Default() {
		t.Errorf("initial Get = %+v, want Default()", got)
	}
	updated := Default()
	updated.DefaultLanguage = Japanese
	s.Set(updated)
	if got := s.Get(); got.DefaultLanguage != Japanese {
		t.Errorf("after Set, lang = %q, want ja", got.DefaultLanguage)
	}
}

func TestStoreConcurrentAccess(t *testing.T) {
	// Run with -race; fails on a data race.
	s := NewStore(Default())
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); s.Set(Default()) }()
		go func() { defer wg.Done(); _ = s.Get() }()
	}
	wg.Wait()
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test -race ./internal/config/`
Expected: FAIL — `undefined: NewStore`

- [ ] **Step 3: Write the implementation**

Create `internal/config/store.go`:

```go
package config

import "sync"

// Store guards a Config for concurrent access: the daemon reads it per
// recording, the IPC handler writes it on setConfig.
type Store struct {
	mu  sync.RWMutex
	cfg Config
}

func NewStore(cfg Config) *Store {
	return &Store{cfg: cfg}
}

func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg
}

func (s *Store) Set(cfg Config) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg = cfg
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test -race ./internal/config/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
go fmt ./internal/config/
git add internal/config/store.go internal/config/store_test.go
git commit -m "Add thread-safe config store"
```

---

### Task 5: Socket server (`internal/ipc/server.go`)

**Files:**
- Create: `internal/ipc/server.go`
- Test: `internal/ipc/server_test.go`

**Interfaces:**
- Consumes: `Bus`, `Event`, `Command`, `Response`, `EncodeLine`, `DecodeCommand` from Tasks 1–2; `*logging.Logger` (existing, has `Printf`)
- Produces (used by Task 6):
  - `type Handler func(cmd Command) (resp Response, shutdown bool)` — `shutdown=true` means: send resp, then call the server's `onShutdown`
  - `func NewServer(path string, bus *Bus, handle Handler, onShutdown func(), logger *logging.Logger) *Server`
  - `func (s *Server) Start() error` — removes a stale socket file, listens, chmods 0600, accepts in background
  - `func (s *Server) Close() error` — stops accepting, removes the socket file

- [ ] **Step 1: Write the failing test**

Create `internal/ipc/server_test.go`. Uses a real Unix socket in `t.TempDir()` (macOS caps socket paths at ~104 bytes; temp dirs are short enough).

```go
package ipc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"voice-inject/internal/logging"
)

func startTestServer(t *testing.T, handle Handler, onShutdown func()) (*Server, *Bus, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.sock")
	bus := NewBus()
	if handle == nil {
		handle = func(cmd Command) (Response, bool) {
			return ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
		}
	}
	if onShutdown == nil {
		onShutdown = func() {}
	}
	srv := NewServer(path, bus, handle, onShutdown, logging.New(os.Stderr))
	if err := srv.Start(); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	return srv, bus, path
}

func dialAndRead(t *testing.T, path string) (net.Conn, *bufio.Scanner) {
	t.Helper()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	return conn, bufio.NewScanner(conn)
}

func TestServerDeliversEventsToClient(t *testing.T) {
	_, bus, path := startTestServer(t, nil, nil)
	_, sc := dialAndRead(t, path)

	// Give the server a moment to register the subscription.
	time.Sleep(50 * time.Millisecond)
	bus.Publish(StateEvent(EventRecording))

	if !sc.Scan() {
		t.Fatalf("no line received: %v", sc.Err())
	}
	if got, want := sc.Text(), `{"type":"event","name":"recording"}`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestServerDispatchesCommandsAndSkipsMalformedLines(t *testing.T) {
	handle := func(cmd Command) (Response, bool) {
		if cmd.Name == CmdStatus {
			return OKResponse(cmd.ID, map[string]string{"state": "idle", "version": "test"}), false
		}
		return ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
	}
	_, _, path := startTestServer(t, handle, nil)
	conn, sc := dialAndRead(t, path)

	// A malformed line, then a real command: the bad line must be
	// skipped without dropping the connection.
	fmt.Fprintf(conn, "this is not json\n")
	fmt.Fprintf(conn, `{"type":"cmd","id":7,"name":"status"}`+"\n")

	if !sc.Scan() {
		t.Fatalf("no response: %v", sc.Err())
	}
	var resp Response
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		t.Fatalf("bad response json: %v", err)
	}
	if resp.ID != 7 || !resp.OK {
		t.Errorf("resp = %+v, want id=7 ok=true", resp)
	}
}

func TestServerUnknownCommandReturnsError(t *testing.T) {
	_, _, path := startTestServer(t, nil, nil)
	conn, sc := dialAndRead(t, path)

	fmt.Fprintf(conn, `{"type":"cmd","id":3,"name":"bogus"}`+"\n")
	if !sc.Scan() {
		t.Fatalf("no response: %v", sc.Err())
	}
	if !strings.Contains(sc.Text(), `"ok":false`) {
		t.Errorf("want ok:false, got %q", sc.Text())
	}
}

func TestServerRemovesStaleSocket(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stale.sock")
	// Simulate a crash leftover: bind and abandon without cleanup.
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	ln.Close() // Close() on unix sockets removes the file...
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err) // ...so recreate a plain file at that path instead.
	}

	bus := NewBus()
	srv := NewServer(path, bus, func(cmd Command) (Response, bool) {
		return ErrResponse(cmd.ID, "x"), false
	}, func() {}, logging.New(os.Stderr))
	if err := srv.Start(); err != nil {
		t.Fatalf("Start over stale socket: %v", err)
	}
	defer srv.Close()

	if _, err := net.Dial("unix", path); err != nil {
		t.Errorf("dial after stale rebind: %v", err)
	}
}

func TestServerShutdownCommand(t *testing.T) {
	shutdownCalled := make(chan struct{})
	handle := func(cmd Command) (Response, bool) {
		if cmd.Name == CmdShutdown {
			return OKResponse(cmd.ID, nil), true
		}
		return ErrResponse(cmd.ID, "unknown"), false
	}
	_, _, path := startTestServer(t, handle, func() { close(shutdownCalled) })
	conn, sc := dialAndRead(t, path)

	fmt.Fprintf(conn, `{"type":"cmd","id":9,"name":"shutdown"}`+"\n")

	// The response must arrive BEFORE the shutdown callback fires.
	if !sc.Scan() {
		t.Fatalf("no shutdown response: %v", sc.Err())
	}
	if !strings.Contains(sc.Text(), `"ok":true`) {
		t.Errorf("want ok:true, got %q", sc.Text())
	}
	select {
	case <-shutdownCalled:
	case <-time.After(2 * time.Second):
		t.Error("onShutdown was not called")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ipc/`
Expected: FAIL — `undefined: NewServer`, `undefined: Handler`

- [ ] **Step 3: Write the implementation**

Create `internal/ipc/server.go`:

```go
package ipc

import (
	"bufio"
	"bytes"
	"errors"
	"io/fs"
	"net"
	"os"

	"voice-inject/internal/logging"
)

// Handler processes one command and returns its response. shutdown=true
// instructs the server to invoke its onShutdown callback after the
// response has been written to the client.
type Handler func(cmd Command) (resp Response, shutdown bool)

// Server accepts Unix-socket clients, streams bus events to them, and
// dispatches their commands to a Handler.
type Server struct {
	path       string
	bus        *Bus
	handle     Handler
	onShutdown func()
	logger     *logging.Logger
	ln         net.Listener
}

func NewServer(path string, bus *Bus, handle Handler, onShutdown func(), logger *logging.Logger) *Server {
	return &Server{path: path, bus: bus, handle: handle, onShutdown: onShutdown, logger: logger}
}

// Start removes any stale socket file, binds, and accepts in the
// background until Close.
func (s *Server) Start() error {
	if err := os.Remove(s.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	ln, err := net.Listen("unix", s.path)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.path, 0o600); err != nil {
		ln.Close()
		return err
	}
	s.ln = ln
	go s.acceptLoop()
	return nil
}

func (s *Server) Close() error {
	if s.ln == nil {
		return nil
	}
	err := s.ln.Close()
	if rmErr := os.Remove(s.path); rmErr != nil && !errors.Is(rmErr, fs.ErrNotExist) {
		s.logger.Printf("[ipc] socket cleanup: %v", rmErr)
	}
	return err
}

func (s *Server) acceptLoop() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return // listener closed
		}
		go s.serveConn(conn)
	}
}

func (s *Server) serveConn(conn net.Conn) {
	defer conn.Close()

	subID, events := s.bus.Subscribe()
	defer s.bus.Unsubscribe(subID)

	out := make(chan []byte, 64)
	done := make(chan struct{})
	writerDone := make(chan struct{})

	// Sole writer to conn: serializes events and responses.
	go func() {
		defer close(writerDone)
		for line := range out {
			if _, err := conn.Write(line); err != nil {
				return
			}
		}
	}()

	// Event forwarder.
	go func() {
		for {
			select {
			case <-done:
				return
			case ev, ok := <-events:
				if !ok {
					return
				}
				line, err := EncodeLine(ev)
				if err != nil {
					s.logger.Printf("[ipc] encode event: %v", err)
					continue
				}
				select {
				case out <- line:
				case <-done:
					return
				}
			}
		}
	}()

	// Reader loop.
	shutdown := false
	sc := bufio.NewScanner(conn)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		cmd, err := DecodeCommand(line)
		if err != nil {
			s.logger.Printf("[ipc] skipping malformed line: %v", err)
			continue
		}
		resp, sd := s.handle(cmd)
		if respLine, err := EncodeLine(resp); err == nil {
			out <- respLine
		} else {
			s.logger.Printf("[ipc] encode response: %v", err)
		}
		if sd {
			shutdown = true
			break
		}
	}

	close(done)
	close(out)
	<-writerDone // flush pending writes before any shutdown
	if shutdown {
		s.onShutdown()
	}
}
```

- [ ] **Step 4: Run tests, including race detector**

Run: `go test -race ./internal/ipc/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
go fmt ./internal/ipc/
git add internal/ipc/server.go internal/ipc/server_test.go
git commit -m "Add IPC Unix socket server with event fanout"
```

---

### Task 6: Command handler + daemon wiring

**Files:**
- Create: `internal/daemon/handler.go`
- Test: `internal/daemon/handler_test.go`
- Modify: `internal/daemon/daemon.go` (whole file shown below)

**Interfaces:**
- Consumes: everything from Tasks 1–5
- Produces:
  - `const Version = "0.1.0"` in package `daemon`
  - `func newHandler(store *config.Store, current *atomic.Int32, cancel context.CancelFunc, logger *logging.Logger) ipc.Handler`
  - `daemon.Run` keeps its exact current signature `Run(ctx context.Context, cfg config.Config, logger *logging.Logger) error` — callers (`commands.RunDaemon`) unchanged

- [ ] **Step 1: Write the failing handler test**

Create `internal/daemon/handler_test.go`:

```go
package daemon

import (
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"

	"voice-inject/internal/config"
	"voice-inject/internal/ipc"
	"voice-inject/internal/logging"
	"voice-inject/internal/state"
)

import "os"

func newTestHandler(t *testing.T) (ipc.Handler, *config.Store, *atomic.Int32, *bool) {
	t.Helper()
	store := config.NewStore(config.Default())
	var current atomic.Int32
	current.Store(int32(state.Idle))
	cancelled := false
	cancel := context.CancelFunc(func() { cancelled = true })
	h := newHandler(store, &current, cancel, logging.New(os.Stderr))
	return h, store, &current, &cancelled
}

func TestHandlerGetConfig(t *testing.T) {
	h, _, _, _ := newTestHandler(t)
	resp, shutdown := h(ipc.Command{Type: ipc.TypeCmd, ID: 1, Name: ipc.CmdGetConfig})
	if shutdown || !resp.OK || resp.ID != 1 {
		t.Fatalf("resp = %+v shutdown=%v", resp, shutdown)
	}
	wire, ok := resp.Data.(config.Wire)
	if !ok {
		t.Fatalf("data is %T, want config.Wire", resp.Data)
	}
	if wire.Lang != "en" || wire.MaxRecordMs != 60000 {
		t.Errorf("wire = %+v, want defaults", wire)
	}
}

func TestHandlerSetConfigAppliesAndValidates(t *testing.T) {
	tests := []struct {
		name   string
		data   string
		wantOK bool
	}{
		{"valid lang change", `{"lang":"ja"}`, true},
		{"invalid lang", `{"lang":"xx"}`, false},
		{"invalid json", `{`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h, store, _, _ := newTestHandler(t)
			resp, _ := h(ipc.Command{Type: ipc.TypeCmd, ID: 2, Name: ipc.CmdSetConfig, Data: json.RawMessage(tt.data)})
			if resp.OK != tt.wantOK {
				t.Fatalf("ok = %v, want %v (err %q)", resp.OK, tt.wantOK, resp.Error)
			}
			if tt.wantOK && store.Get().DefaultLanguage != config.Japanese {
				t.Error("store not updated")
			}
			if !tt.wantOK && store.Get().DefaultLanguage != config.English {
				t.Error("store mutated on failed setConfig")
			}
		})
	}
}

func TestHandlerStatus(t *testing.T) {
	h, _, current, _ := newTestHandler(t)
	current.Store(int32(state.Recording))
	resp, _ := h(ipc.Command{Type: ipc.TypeCmd, ID: 3, Name: ipc.CmdStatus})
	data, ok := resp.Data.(map[string]string)
	if !ok {
		t.Fatalf("data is %T, want map[string]string", resp.Data)
	}
	if data["state"] != "recording" || data["version"] != Version {
		t.Errorf("status = %v", data)
	}
}

func TestHandlerShutdown(t *testing.T) {
	h, _, _, cancelled := newTestHandler(t)
	resp, shutdown := h(ipc.Command{Type: ipc.TypeCmd, ID: 4, Name: ipc.CmdShutdown})
	if !resp.OK || !shutdown {
		t.Fatalf("resp = %+v shutdown = %v, want ok+shutdown", resp, shutdown)
	}
	_ = cancelled // cancel is invoked by the server via onShutdown, not by the handler
}

func TestHandlerUnknownCommand(t *testing.T) {
	h, _, _, _ := newTestHandler(t)
	resp, shutdown := h(ipc.Command{Type: ipc.TypeCmd, ID: 5, Name: "bogus"})
	if resp.OK || shutdown {
		t.Fatalf("resp = %+v, want ok=false", resp)
	}
}
```

Note on `setConfig` persistence: the handler also calls `Save()`, which writes to the real home directory. To keep the unit test hermetic, `newHandler` takes a save function; see the implementation — the test above passes because `newTestHandler` wires a no-op save:

Adjust `newTestHandler` accordingly once you reach Step 3 (the final signature is `newHandler(store, current, cancel, save, logger)` with `save func(config.Config) error`); use `func(config.Config) error { return nil }` in tests.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/daemon/`
Expected: FAIL — `undefined: newHandler`, `undefined: Version`

- [ ] **Step 3: Write the handler**

Create `internal/daemon/handler.go`:

```go
package daemon

import (
	"context"
	"sync/atomic"

	"voice-inject/internal/config"
	"voice-inject/internal/ipc"
	"voice-inject/internal/logging"
	"voice-inject/internal/state"
)

// Version is reported by the status command.
const Version = "0.1.0"

// newHandler builds the IPC command handler. cancel stops the daemon
// (invoked by the server's onShutdown after the response is flushed).
// save persists the config after a successful setConfig; pass
// config.Config.Save in production and a stub in tests.
func newHandler(store *config.Store, current *atomic.Int32, cancel context.CancelFunc, save func(config.Config) error, logger *logging.Logger) ipc.Handler {
	_ = cancel // cancellation happens via the server's onShutdown callback
	return func(cmd ipc.Command) (ipc.Response, bool) {
		switch cmd.Name {
		case ipc.CmdGetConfig:
			return ipc.OKResponse(cmd.ID, store.Get().ToWire()), false

		case ipc.CmdSetConfig:
			updated, err := store.Get().ApplyPatch(cmd.Data)
			if err != nil {
				return ipc.ErrResponse(cmd.ID, err.Error()), false
			}
			store.Set(updated)
			if err := save(updated); err != nil {
				logger.Printf("[ipc] config save failed: %v", err)
				return ipc.ErrResponse(cmd.ID, "applied but not saved: "+err.Error()), false
			}
			return ipc.OKResponse(cmd.ID, nil), false

		case ipc.CmdStatus:
			return ipc.OKResponse(cmd.ID, map[string]string{
				"state":   state.State(current.Load()).String(),
				"version": Version,
			}), false

		case ipc.CmdShutdown:
			return ipc.OKResponse(cmd.ID, nil), true

		default:
			return ipc.ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
		}
	}
}
```

- [ ] **Step 4: Run handler tests**

Run: `go test ./internal/daemon/`
Expected: PASS (after aligning `newTestHandler` with the `save` parameter as noted in Step 1)

- [ ] **Step 5: Commit the handler**

```bash
go fmt ./internal/daemon/
git add internal/daemon/handler.go internal/daemon/handler_test.go
git commit -m "Add IPC command handler for daemon"
```

- [ ] **Step 6: Wire events and server into the daemon loop**

Replace `internal/daemon/daemon.go` with:

```go
package daemon

import (
	"context"
	"fmt"
	"os"
	"sync/atomic"
	"time"

	"voice-inject/internal/config"
	"voice-inject/internal/inject"
	"voice-inject/internal/ipc"
	"voice-inject/internal/logging"
	"voice-inject/internal/postprocess"
	"voice-inject/internal/record"
	"voice-inject/internal/state"
	"voice-inject/internal/transcribe"

	"golang.design/x/hotkey"
)

func Run(ctx context.Context, cfg config.Config, logger *logging.Logger) error {
	return run(ctx, cfg, logger)
}

func run(ctx context.Context, cfg config.Config, logger *logging.Logger) error {
	if _, err := os.Stat(cfg.WhisperModel); err != nil {
		return fmt.Errorf("whisper model not found at %s: %w", cfg.WhisperModel, err)
	}
	if err := inject.CheckAccessibility(); err != nil {
		return fmt.Errorf("accessibility check failed: %w", err)
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	store := config.NewStore(cfg)
	bus := ipc.NewBus()
	var current atomic.Int32
	current.Store(int32(state.Idle))

	setState := func(s state.State, ev string) {
		current.Store(int32(s))
		logger.State(s.String())
		bus.Publish(ipc.StateEvent(ev))
	}

	socketPath, err := config.SocketPath()
	if err != nil {
		return fmt.Errorf("resolve socket path: %w", err)
	}
	handler := newHandler(store, &current, cancel, config.Config.Save, logger)
	srv := ipc.NewServer(socketPath, bus, handler, cancel, logger)
	if err := srv.Start(); err != nil {
		return fmt.Errorf("start ipc server: %w", err)
	}
	defer srv.Close()

	// Register hotkey for recording
	hk := hotkey.New([]hotkey.Modifier{hotkey.ModOption}, hotkey.KeySpace)
	if err := hk.Register(); err != nil {
		return fmt.Errorf("failed to register hotkey: %w", err)
	}
	defer hk.Unregister()

	setState(state.Idle, ipc.EventIdle)

	for {
		select {
		case <-ctx.Done():
			logger.Printf("[daemon] stopped")
			return nil
		case <-hk.Keydown():
			if err := handleRecording(ctx, hk, store, bus, setState, logger); err != nil {
				logger.Printf("recording error: %v", err)
			}
			setState(state.Idle, ipc.EventIdle)
		}
	}
}

func handleRecording(ctx context.Context, hk *hotkey.Hotkey, store *config.Store, bus *ipc.Bus, setState func(state.State, string), logger *logging.Logger) error {
	cfg := store.Get() // pick up live config changes per recording

	started := time.Now()
	rec, err := record.Start(ctx, logger)
	if err != nil {
		bus.Publish(ipc.ErrorEvent("record", err.Error()))
		return fmt.Errorf("record error: %w", err)
	}
	setState(state.Recording, ipc.EventRecording)

	// Wait for key release or context cancellation
	select {
	case <-hk.Keyup():
		// normal flow — continue to stop/transcribe/inject
	case <-ctx.Done():
		rec.Stop()
		rec.Cleanup()
		return ctx.Err()
	}

	// Stop recording
	wavPath, err := rec.Stop()
	durationMs := time.Since(started).Milliseconds()
	if err != nil {
		rec.Cleanup()
		bus.Publish(ipc.ErrorEvent("record", err.Error()))
		return fmt.Errorf("stop recording error: %w", err)
	}
	setState(state.Transcribing, ipc.EventTranscribing)

	// Transcribe
	text, err := transcribe.Run(ctx, wavPath, cfg.WhisperModel, string(cfg.DefaultLanguage), logger)
	if err != nil {
		rec.Cleanup()
		bus.Publish(ipc.ErrorEvent("transcribe", err.Error()))
		return fmt.Errorf("transcribe error: %w", err)
	}

	// Postprocess
	text = postprocess.Normalize(text)

	// Validate
	if err := postprocess.Validate(text, cfg); err != nil {
		rec.Cleanup()
		bus.Publish(ipc.ErrorEvent("validate", err.Error()))
		return fmt.Errorf("validation error: %w", err)
	}

	// Inject
	setState(state.Injecting, ipc.EventTranscribing) // no dedicated event; HUD keeps spinner until idle
	if err := inject.Paste(text, logger); err != nil {
		bus.Publish(ipc.ErrorEvent("inject", err.Error()))
		return fmt.Errorf("inject error: %w", err)
	}

	bus.Publish(ipc.TranscriptEvent(text, string(cfg.DefaultLanguage), durationMs))
	return nil
}
```

Notes for the implementer:
- `setState` is the single place that mutates `current`, logs, and publishes — keeps the three views of state in sync.
- The `Injecting` internal state deliberately re-publishes `transcribing`: the spec's event vocabulary has no `injecting` event and the HUD treats everything between key-release and `idle` as "working".
- The server's `onShutdown` is the daemon's `cancel` — a `shutdown` command flushes its response, then cancels the run context, and `Run` returns nil exactly like Ctrl+C.

- [ ] **Step 7: Compile and run all tests**

Run: `go build ./... && go test -race ./...`
Expected: everything compiles; all tests PASS.

- [ ] **Step 8: Commit**

```bash
go fmt ./...
git add internal/daemon/daemon.go
git commit -m "Publish IPC events from daemon state machine"
```

---

### Task 7: Load config file at startup + `-managed` stdin-EOF flag

**Files:**
- Modify: `cmd/voice-inject/main.go` (daemon case only, lines 28–45)

**Interfaces:**
- Consumes: `config.Load()` from Task 3
- Produces: `voice-inject daemon -managed` CLI contract relied on by issue #29 (the Swift app spawns the daemon with this flag and a stdin pipe)

- [ ] **Step 1: Modify the daemon case in `cmd/voice-inject/main.go`**

Replace the `case "daemon":` block with:

```go
	case "daemon":
		daemonFlags := flag.NewFlagSet("daemon", flag.ExitOnError)
		lang := daemonFlags.String("lang", "", "language to use for transcription (en, ja); overrides the config file")
		managed := daemonFlags.Bool("managed", false, "exit when stdin closes (for supervision by a parent app)")
		daemonFlags.Parse(os.Args[2:])
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
		defer cancel() // cleanup when main function returns
		logger := logging.New(os.Stdout)
		cfg, err := config.Load()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error loading config: %v\n", err)
			os.Exit(1)
		}
		if *lang != "" {
			langVal := config.Language(*lang)
			if !config.ValidLanguage(langVal) {
				fmt.Fprintf(os.Stderr, "unsupported language: %q (supported: en, ja)\n", *lang)
				os.Exit(1)
			}
			cfg.DefaultLanguage = langVal
		}
		if *managed {
			go func() {
				// Parent-death detection: the supervising app holds our
				// stdin pipe open; EOF means the parent is gone.
				io.Copy(io.Discard, os.Stdin)
				cancel()
			}()
		}
		if err := commands.RunDaemon(ctx, cfg, logger); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
```

Add `"io"` to the imports.

Behavior change to be aware of: `-lang` now defaults to empty ("use the config file") instead of `"en"`. `config.Load()` returns `Default()` (lang `en`) when no file exists, so the out-of-the-box behavior is identical.

- [ ] **Step 2: Compile and run all tests**

Run: `go build ./... && go test -race ./...`
Expected: PASS

- [ ] **Step 3: Verify the managed flag manually**

```bash
go build ./cmd/voice-inject
# stdin EOF must terminate a managed daemon quickly:
(echo -n | ./voice-inject daemon -managed); echo "exit: $?"
```
Expected: the daemon starts, its stdin is already at EOF, and it exits within a second printing `[daemon] stopped` (exit 0). An UNMANAGED daemon must NOT do this: `./voice-inject daemon < /dev/null` keeps running (Ctrl+C to stop).

(If the model file or Accessibility pre-checks fail on your machine, both invocations exit 1 with that error instead — fix the pre-check first.)

- [ ] **Step 4: Commit**

```bash
go fmt ./...
git add cmd/voice-inject/main.go
git commit -m "Load config file at startup and add -managed flag"
```

---

### Task 8: End-to-end acceptance with `nc -U`

**Files:** none (manual verification, mirrors issue #28 acceptance criteria)

- [ ] **Step 1: Build and start the daemon**

```bash
go build ./cmd/voice-inject && ./voice-inject daemon
```

- [ ] **Step 2: In a second terminal, connect and watch events**

```bash
nc -U ~/Library/Application\ Support/voice-inject/daemon.sock
```

Hold Option+Space, say "hello world testing one two three", release.
Expected output (text will differ):

```
{"type":"event","name":"recording"}
{"type":"event","name":"transcribing"}
{"type":"event","name":"transcript","data":{"text":"Hello world testing one two three","lang":"en","durationMs":2800}}
{"type":"event","name":"idle"}
```

- [ ] **Step 3: Exercise every command in the same `nc` session (type each line)**

```
{"type":"cmd","id":1,"name":"status"}
{"type":"cmd","id":2,"name":"getConfig"}
{"type":"cmd","id":3,"name":"setConfig","data":{"lang":"ja"}}
{"type":"cmd","id":4,"name":"setConfig","data":{"lang":"xx"}}
not even json
{"type":"cmd","id":5,"name":"shutdown"}
```

Expected, in order:
1. `{"type":"resp","id":1,"ok":true,"data":{"state":"idle","version":"0.1.0"}}`
2. `ok:true` with the full config wire object
3. `ok:true`; `cat ~/Library/Application\ Support/voice-inject/config.json` now shows `"lang": "ja"`
4. `ok:false` with `unsupported language: "xx"`
5. nothing back (skipped + logged in the daemon terminal), connection stays open
6. `ok:true`, then the daemon prints `[daemon] stopped` and exits 0

- [ ] **Step 4: Confirm CLI-only behavior is unchanged**

Run `./voice-inject daemon` with no client connected and dictate once — pastes exactly as before this change. Check `ls -l ~/Library/Application\ Support/voice-inject/daemon.sock` shows `srw-------` (0600).

- [ ] **Step 5: Restart the daemon while a stale socket exists**

Kill the daemon with `kill -9 <pid>` (leaves the socket file behind), restart it, and confirm it binds without error and `nc -U` connects.

---

## Self-Review (completed at plan time)

- **Spec coverage:** socket path/permissions (T5/T8), stale rebind (T5/T8), event shapes (T1), bus zero-subscriber (T2), config file + missing-file default (T3), live setConfig + persistence (T3/T4/T6), status with version (T6), shutdown ordering (T5/T6), malformed-line tolerance (T5/T8), `-managed` stdin EOF for #29 (T7), CLI unchanged (T6 signature note, T8). Pre-check→error-events explicitly deferred to Phase 5 per Global Constraints.
- **Type consistency:** `ipc.Handler` returns `(Response, bool)` everywhere; `newHandler` takes the `save` func in both test note and implementation; `config.Wire` field names match across Tasks 3, 6, and 8 expectations.
