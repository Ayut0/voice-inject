package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"

	"voice-inject/internal/commands"
	"voice-inject/internal/config"
	"voice-inject/internal/logging"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] == "--help" || os.Args[1] == "-h" {
		commands.PrintUsage(os.Stdout)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "daemon":
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
		defer cancel() // cleanup when main function returns
		logger := logging.New(os.Stdout)
		cfg := config.Default()
		if err := commands.RunDaemon(ctx, cfg, logger); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	case "inject":
		logger := logging.New(os.Stdout)
		cfg := config.Default()
		if err := commands.RunInject(os.Stdin, cfg, logger); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintln(os.Stdout, "unknown command")
		os.Exit(2)
	}
}
