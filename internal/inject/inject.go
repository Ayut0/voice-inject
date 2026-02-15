// The clipboard injector

package inject

import (
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"voice-inject/internal/logging"
)

func Paste(text string, logger *logging.Logger) error {
	trimmed := strings.TrimSpace(text)

	if trimmed == "" {
		return fmt.Errorf("empty text")
	}

	//After this line, err is either:
	// - nil -> no error, it worked
	// - not nil -> something went wrong
	if err := runPbCopy(text); err != nil {
		// if error, execute this code
		return fmt.Errorf("failed to run pbcopy: %w", err)
	}

	if err := runPaste(); err != nil {
		return fmt.Errorf("failed to run paste: %w", err)
	}

	logger.State("inject", "ok", "chars="+strconv.Itoa(len([]rune(trimmed))))

	return nil
}

func runPbCopy(text string) error {
	cmd := exec.Command("pbcopy")
	// It's like running echo "hello" | pbcopy in the terminal
	cmd.Stdin = bytes.NewBufferString(text)
	return cmd.Run()
}

func runPaste() error {
	cmd := exec.Command("osascript", "-e", "tell application \"System Events\" to keystroke \"v\" using command down")

	err := cmd.Run()
	if err != nil {
		return fmt.Errorf("failed to run osascript (Is Accessibility enabled?): %w", err)
	}
	return nil
}
