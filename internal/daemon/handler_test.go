package daemon

import (
	"context"
	"encoding/json"
	"os"
	"sync/atomic"
	"testing"

	"voice-inject/internal/config"
	"voice-inject/internal/ipc"
	"voice-inject/internal/logging"
	"voice-inject/internal/state"
)

func newTestHandler(t *testing.T) (ipc.Handler, *config.Store, *atomic.Int32, *bool) {
	t.Helper()
	store := config.NewStore(config.Default())
	var current atomic.Int32
	current.Store(int32(state.Idle))
	cancelled := false
	cancel := context.CancelFunc(func() { cancelled = true })
	save := func(config.Config) error { return nil }
	h := newHandler(store, &current, cancel, save, logging.New(os.Stderr))
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
	tests := []struct {
		name      string
		setState  state.State
		wantState string
	}{
		{"idle", state.Idle, "idle"},
		{"recording", state.Recording, "recording"},
		{"transcribing", state.Transcribing, "transcribing"},
		{"injecting collapses to transcribing", state.Injecting, "transcribing"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h, _, current, _ := newTestHandler(t)
			current.Store(int32(tt.setState))
			resp, _ := h(ipc.Command{Type: ipc.TypeCmd, ID: 3, Name: ipc.CmdStatus})
			data, ok := resp.Data.(map[string]string)
			if !ok {
				t.Fatalf("data is %T, want map[string]string", resp.Data)
			}
			if data["state"] != tt.wantState || data["version"] != Version {
				t.Errorf("status = %v, want state=%q", data, tt.wantState)
			}
		})
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
