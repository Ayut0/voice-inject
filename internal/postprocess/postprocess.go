package postprocess

import (
	"fmt"
	"strings"
	"unicode"
	"voice-inject/internal/config"
)

// Normalize trims whitespace and normalizes spaces.
func Normalize(input string) string {
	trimmed := strings.TrimSpace(input)
	return normalizeSpaces(trimmed)
}

// normalizeSpaces normalizes spaces by joining adjacent whitespace with a single space.
func normalizeSpaces(input string) string {
	fields := strings.Fields(input)
	return strings.Join(fields, " ")
}

func Validate(text string, cfg config.Config) error {
	if len(text) < cfg.MinTextLength {
		return fmt.Errorf("text too short (%d char, min %d)", len(text), cfg.MinTextLength)
	}

	if len(text) > cfg.MaxTextLength {
		return fmt.Errorf("text too long (%d char, max %d)", len(text), cfg.MaxTextLength)
	}

	symbols := 0
	for _, r := range text {
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && !unicode.IsSpace(r) {
			symbols++
		}
	}

	if len(text) > 0 && float64(symbols)/float64(len(text)) > cfg.MaxSymbolRatio {
		return fmt.Errorf("abnormal symbols")
	}

	return nil
}
