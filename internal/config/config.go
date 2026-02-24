package config

import (
	"os"
	"path/filepath"
	"time"
)

type Language string

const (
	English  Language = "en"
	Japanese Language = "ja"
)

type Config struct {
	MinRecordDuration time.Duration
	MaxRecordDuration time.Duration
	SilenceTimeout    time.Duration
	DefaultLanguage   Language
	MinTextLength     int
	MaxTextLength     int
	CamelCaseRule     bool
	WhisperModel      string
}

// ValidLanguage reports whether lang is a supported language.
func ValidLanguage(lang Language) bool {
	switch lang {
	case English, Japanese:
		return true
	}
	return false
}

func defaultModelPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}

	return filepath.Join(home, ".local", "share", "whisper-cpp", "models", "ggml-base.bin")
}

func Default() Config {
	return Config{
		MinRecordDuration: 700 * time.Millisecond,
		MaxRecordDuration: 60 * time.Second,
		SilenceTimeout:    4 * time.Second,
		DefaultLanguage:   English,
		MinTextLength:     3,
		MaxTextLength:     5000,
		CamelCaseRule:     false,
		WhisperModel:      defaultModelPath(),
	}
}
