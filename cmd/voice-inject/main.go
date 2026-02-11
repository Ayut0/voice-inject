package main

import (
	"fmt"
	"os"

	"voice-inject/internal/commands"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] == "--help" || os.Args[1] == "-h" {
		commands.PrintUsage(os.Stdout)
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
