package record

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"voice-inject/internal/logging"
)

type Recorder struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	outPath string
	logger  *logging.Logger
}

// Start begins recording audio to a temporary WAV file.
// Returns immediately — audio is captured in the background by ffmpeg.
func Start(logger *logging.Logger) (*Recorder, error) {
	// create a temporary file for the recording
	outPath := filepath.Join(os.TempDir(), "voice-inject-recording.wav")

	cmd := exec.Command("ffmpeg", "-f", "avfoundation", "-i", ":0", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", outPath)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("failed to get stdin pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start ffmpeg: %w", err)
	}

	logger.State("recording")

	return &Recorder{
		cmd:     cmd,
		stdin:   stdin,
		outPath: outPath,
		logger:  logger,
	}, nil

}

// Stop ends the recording gracefully by sending "q" to ffmpeg's stdin.
// Returns the path to the recorded WAV file.
func (r *Recorder) Stop() (string, error) {
	// Send "q" to ffmpeg to stop gracefully (finalizes WAV header)
	_, err := r.stdin.Write([]byte("q"))

	if err != nil {
		return "", fmt.Errorf("failed to write to stdin: %w", err)
	}
	r.stdin.Close()

	if err := r.cmd.Wait(); err != nil {
		return "", fmt.Errorf("ffmpeg exited with error: %w", err)
	}

	// returns the path to the recorded WAV file
	r.logger.State("recording stopped", "file="+r.outPath)
	return r.outPath, nil
}

// Cleanup removes the temporary WAV file.
func (r *Recorder) Cleanup() {
	os.Remove(r.outPath)
}
