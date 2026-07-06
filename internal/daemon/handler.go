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

// statusState returns the state string for IPC status responses, collapsing the
// internal Injecting state to "transcribing" to match the IPC event vocabulary.
// The IPC event stream does not publish "injecting" events; Injecting is an
// internal-only state that logically represents ongoing post-transcription work.
func statusState(s state.State) string {
	if s == state.Injecting {
		return "transcribing"
	}
	return s.String()
}

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
				"state":   statusState(state.State(current.Load())),
				"version": Version,
			}), false

		case ipc.CmdShutdown:
			return ipc.OKResponse(cmd.ID, nil), true

		default:
			return ipc.ErrResponse(cmd.ID, "unknown command: "+cmd.Name), false
		}
	}
}
