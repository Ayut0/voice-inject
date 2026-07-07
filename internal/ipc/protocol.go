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
