package daemon

import (
	"context"
	"fmt"
	"os"

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
	if _, err := os.Stat(cfg.WhisperModel); err != nil {
		return fmt.Errorf("whisper model not found at %s: %w", cfg.WhisperModel, err)
	}
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
			if err := handleRecording(ctx, hk, cfg, logger); err != nil {
				logger.Printf("recording error: %v", err)
			}
			logger.State(state.Idle.String())
		}
	}
}

func handleRecording(ctx context.Context, hk *hotkey.Hotkey, cfg config.Config, logger *logging.Logger) error {
	// Start recording
	rec, err := record.Start(ctx, logger)
	if err != nil {
		return fmt.Errorf("record error: %w", err)
	}

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
	if err != nil {
		rec.Cleanup()
		return fmt.Errorf("stop recording error: %w", err)
	}

	// Transcribe
	text, err := transcribe.Run(ctx, wavPath, cfg.WhisperModel, string(cfg.DefaultLanguage), logger)
	if err != nil {
		rec.Cleanup()
		return fmt.Errorf("transcribe error: %w", err)
	}

	// Postprocess
	text = postprocess.Normalize(text)

	// Validate
	if err := postprocess.Validate(text, cfg); err != nil {
		rec.Cleanup()
		return fmt.Errorf("validation error: %w", err)
	}

	// Inject
	if err := inject.Paste(text, logger); err != nil {
		return fmt.Errorf("inject error: %w", err)
	}

	return nil
}
