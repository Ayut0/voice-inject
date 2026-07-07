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
