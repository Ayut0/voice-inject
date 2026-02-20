package record

import (
	"fmt"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"voice-inject/internal/logging"
)

var ErrNotImplemented = errors.New("recording not implemented")

type Recorder struct {
	cmd *exec.Cmd
	stdin io.WriteCloser
	outPath string
	logger *logging.Logger
}

func Start (logger *logging.Logger) (*Recorder, error) {
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
		cmd: cmd,
		stdin: stdin,
		outPath: outPath,
		logger: logger,
	}, nil


}

func Stop (){

}

func Cleanup () {

}