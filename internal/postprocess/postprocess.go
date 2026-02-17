package postprocess

import "strings"

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
