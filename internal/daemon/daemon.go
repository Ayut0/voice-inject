package daemon

import (
	"context"
	"voice-inject/internal/config"
	"voice-inject/internal/logging"
	"voice-inject/internal/state"
)

func Run(ctx context.Context, cfg config.Config, logger *logging.Logger) error {
	_ = cfg

	logger.State(state.Idle.String())
	<-ctx.Done()
	logger.Printf("[daemon] stopped")
	return nil // everything went fine, no error
}
