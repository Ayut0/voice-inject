package config

import "time"

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
	}
}
