package logging

import (
	"fmt"
	"io"
	"strings"
)

type Logger struct {
	out io.Writer
}

// New creates a new Logger that writes to the given io.Writer.
func New(w io.Writer) *Logger {
	return &Logger{out: w}
}

// Printf prints a formatted message to the logger's output.
func (l *Logger) Printf(format string, args ...any) {
	fmt.Fprintf(l.out, format+"\n", args...)
}

func (l *Logger) State(state string, tokens ...string) {
	line := "[" + state + "]"
	if len(tokens) > 0 {
		line += " " + strings.Join(tokens, " ")
	}
	fmt.Fprintln(l.out, line)
}
