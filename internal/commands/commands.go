// Internal layer between main.go and the internal packages

package commands

import (
	"context"
	"fmt"
	"io"
	"strings"
	"voice-inject/internal/config"
	"voice-inject/internal/daemon"
	"voice-inject/internal/inject"
	"voice-inject/internal/logging"
)

func PrintUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: voice-inject <command>")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Commands:")
	fmt.Fprintln(w, "  daemon   Run the background hotkey listener")
	fmt.Fprintln(w, "  inject   Read stdin and paste it (debug)")
}

func RunDaemon(ctx context.Context, cfg config.Config, logger *logging.Logger) error {
	return daemon.Run(ctx, cfg, logger)
}

func RunInject(r io.Reader, cfg config.Config, logger *logging.Logger) error {
	_ = cfg
	input, err := io.ReadAll(r)
	if err != nil {
		return fmt.Errorf("failed to read input: %w", err)
	}

	text := strings.TrimSpace(string(input))
	if text == "" {
		return fmt.Errorf("empty input")
	}

	return inject.Paste(text, logger)
}
