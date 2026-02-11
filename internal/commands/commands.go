package commands

import (
	"fmt"
	"io"
)

func PrintUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: voice-inject <command>")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Commands:")
	fmt.Fprintln(w, "  daemon   Run the background hotkey listener")
	fmt.Fprintln(w, "  inject   Read stdin and paste it (debug)")
}
