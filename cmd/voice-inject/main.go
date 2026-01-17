package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] == "--help" || os.Args[1] == "-h" {
		fmt.Fprintln(os.Stdout, "Usage: voice-inject <command>")
		fmt.Fprintln(os.Stdout, "")
		fmt.Fprintln(os.Stdout, "Commands:")
		fmt.Fprintln(os.Stdout, "  daemon   Run the background hotkey listener")
		fmt.Fprintln(os.Stdout, "  inject   Read stdin and paste it (debug)")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "daemon":
		fmt.Fprintln(os.Stdout, "daemon selected")
	case "inject":
		fmt.Fprintln(os.Stdout, "inject selected")
	default:
		fmt.Fprintln(os.Stdout, "unknown command")
		os.Exit(2)
	}
}
