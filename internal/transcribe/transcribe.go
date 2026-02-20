package transcribe

import (
	"fmt"
	"os/exec"
	"strings"
	"voice-inject/internal/logging"
)

func Run(wavPath string, modelPath string, lang string, logger *logging.Logger) (string, error) {
	logger.State("transcribing", "model="+modelPath)

	cmd := exec.Command("whisper-cli", "-m", modelPath, "-f", wavPath, "--no-timestamps", "-l", lang)

	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("whisper-cli failed: %w", err)
	}

	text := strings.TrimSpace(string(output))
	if text == "" {
		return "", fmt.Errorf("whisper-cli returned empty output")
	}

	return text, nil
}
