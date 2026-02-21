package daemon

import (
	"context"
	"fmt"

	"voice-inject/internal/config"
	"voice-inject/internal/inject"
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
	// Register hotkey for recording
	hk := hotkey.New([]hotkey.Modifier{hotkey.ModOption}, hotkey.KeySpace)
	if err := hk.Register(); err != nil {
		return fmt.Errorf("failed to register hotkey: %w", err)
	}
	defer hk.Unregister()

	logger.State(state.Idle.String())

	for {
		select {
		case <-ctx.Done():
			logger.Printf("[daemon] stopped")
			return nil
		case <-hk.Keydown():
			// Start recording
			rec, err := record.Start(logger)
			if err != nil {
				logger.Printf("record error: %v", err)
				continue
			}

			// wait for key release
			<-hk.Keyup()

			// Stop recording
			wavPath, err := rec.Stop()
			if err != nil {
				logger.Printf("stop recording error: %v", err)
				rec.Cleanup()
				logger.State(state.Idle.String())
				continue
			}

			// Transcribe
			text, err := transcribe.Run(wavPath, cfg.WhisperModel, string(cfg.DefaultLanguage), logger)
			if err != nil {
				logger.Printf("transcribe error: %v", err)
				rec.Cleanup()
				logger.State(state.Idle.String())
				continue
			}

			// Postprocess
			text = postprocess.Normalize(text)

			// Inject
			if err := inject.Paste(text, logger); err != nil {
				logger.Printf("inject error: %v", err)
			}

			logger.State(state.Idle.String())
		}
	}
}
