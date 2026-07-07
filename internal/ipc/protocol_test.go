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
