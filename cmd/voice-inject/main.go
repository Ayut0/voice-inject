package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"

	"voice-inject/internal/commands"
	"voice-inject/internal/config"
	"voice-inject/internal/logging"

	"golang.design/x/hotkey/mainthread"
)

func main() {
	mainthread.Init(run)
}

func run() {
	if len(os.Args) < 2 || os.Args[1] == "--help" || os.Args[1] == "-h" {
		commands.PrintUsage(os.Stdout)
		os.Exit(2)
	}

	switch os.Args[1] {
	case "daemon":
		daemonFlags := flag.NewFlagSet("daemon", flag.ExitOnError)
		lang := daemonFlags.String("lang", "", "language to use for transcription (en, ja); overrides the config file")
		managed := daemonFlags.Bool("managed", false, "exit when stdin closes (for supervision by a parent app)")
		daemonFlags.Parse(os.Args[2:])
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
		defer cancel() // cleanup when main function returns
		logger := logging.New(os.Stdout)
		cfg, err := config.Load()
		if err != nil {
			fmt.Fprintf(os.Stderr, "error loading config: %v\n", err)
			os.Exit(1)
		}
		if *lang != "" {
			langVal := config.Language(*lang)
			if !config.ValidLanguage(langVal) {
				fmt.Fprintf(os.Stderr, "unsupported language: %q (supported: en, ja)\n", *lang)
				os.Exit(1)
			}
			cfg.DefaultLanguage = langVal
		}
		if *managed {
			go func() {
				// Parent-death detection: the supervising app holds our
				// stdin pipe open; EOF means the parent is gone.
				io.Copy(io.Discard, os.Stdin)
				cancel()
			}()
		}
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
