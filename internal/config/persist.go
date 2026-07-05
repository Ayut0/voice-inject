package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// Wire is the JSON representation of Config, shared by the config file
// and the IPC getConfig/setConfig payloads. Durations are milliseconds.
type Wire struct {
	Lang             string  `json:"lang"`
	Model            string  `json:"model"`
	MinRecordMs      int64   `json:"minRecordMs"`
	MaxRecordMs      int64   `json:"maxRecordMs"`
	SilenceTimeoutMs int64   `json:"silenceTimeoutMs"`
	MinTextLength    int     `json:"minTextLength"`
	MaxTextLength    int     `json:"maxTextLength"`
	CamelCaseRule    bool    `json:"camelCaseRule"`
	MaxSymbolRatio   float64 `json:"maxSymbolRatio"`
}

func (c Config) ToWire() Wire {
	return Wire{
		Lang:             string(c.DefaultLanguage),
		Model:            c.WhisperModel,
		MinRecordMs:      c.MinRecordDuration.Milliseconds(),
		MaxRecordMs:      c.MaxRecordDuration.Milliseconds(),
		SilenceTimeoutMs: c.SilenceTimeout.Milliseconds(),
		MinTextLength:    c.MinTextLength,
		MaxTextLength:    c.MaxTextLength,
		CamelCaseRule:    c.CamelCaseRule,
		MaxSymbolRatio:   c.MaxSymbolRatio,
	}
}

func (w Wire) ToConfig() Config {
	return Config{
		DefaultLanguage:   Language(w.Lang),
		WhisperModel:      w.Model,
		MinRecordDuration: time.Duration(w.MinRecordMs) * time.Millisecond,
		MaxRecordDuration: time.Duration(w.MaxRecordMs) * time.Millisecond,
		SilenceTimeout:    time.Duration(w.SilenceTimeoutMs) * time.Millisecond,
		MinTextLength:     w.MinTextLength,
		MaxTextLength:     w.MaxTextLength,
		CamelCaseRule:     w.CamelCaseRule,
		MaxSymbolRatio:    w.MaxSymbolRatio,
	}
}

// ApplyPatch returns a copy of c with the non-null fields of the JSON
// patch applied. Unknown fields are ignored.
func (c Config) ApplyPatch(raw []byte) (Config, error) {
	var p struct {
		Lang             *string  `json:"lang"`
		Model            *string  `json:"model"`
		MinRecordMs      *int64   `json:"minRecordMs"`
		MaxRecordMs      *int64   `json:"maxRecordMs"`
		SilenceTimeoutMs *int64   `json:"silenceTimeoutMs"`
		MinTextLength    *int     `json:"minTextLength"`
		MaxTextLength    *int     `json:"maxTextLength"`
		CamelCaseRule    *bool    `json:"camelCaseRule"`
		MaxSymbolRatio   *float64 `json:"maxSymbolRatio"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return Config{}, fmt.Errorf("invalid patch: %w", err)
	}
	if p.Lang != nil {
		if !ValidLanguage(Language(*p.Lang)) {
			return Config{}, fmt.Errorf("unsupported language: %q", *p.Lang)
		}
		c.DefaultLanguage = Language(*p.Lang)
	}
	if p.Model != nil {
		c.WhisperModel = *p.Model
	}
	if p.MinRecordMs != nil {
		c.MinRecordDuration = time.Duration(*p.MinRecordMs) * time.Millisecond
	}
	if p.MaxRecordMs != nil {
		c.MaxRecordDuration = time.Duration(*p.MaxRecordMs) * time.Millisecond
	}
	if p.SilenceTimeoutMs != nil {
		c.SilenceTimeout = time.Duration(*p.SilenceTimeoutMs) * time.Millisecond
	}
	if p.MinTextLength != nil {
		c.MinTextLength = *p.MinTextLength
	}
	if p.MaxTextLength != nil {
		c.MaxTextLength = *p.MaxTextLength
	}
	if p.CamelCaseRule != nil {
		c.CamelCaseRule = *p.CamelCaseRule
	}
	if p.MaxSymbolRatio != nil {
		c.MaxSymbolRatio = *p.MaxSymbolRatio
	}
	return c, nil
}

// Dir returns the app's support directory, creating it if needed.
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, "Library", "Application Support", "voice-inject")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// SocketPath returns the daemon's Unix socket path.
func SocketPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "daemon.sock"), nil
}

// LoadFrom reads a config file. A missing file is not an error: it
// returns Default().
func LoadFrom(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Default(), nil
	}
	if err != nil {
		return Config{}, err
	}
	var w Wire
	if err := json.Unmarshal(b, &w); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return w.ToConfig(), nil
}

// SaveTo writes the config as indented JSON, mode 0600.
func (c Config) SaveTo(path string) error {
	b, err := json.MarshalIndent(c.ToWire(), "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func configPath() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// Load reads the default config file location.
func Load() (Config, error) {
	path, err := configPath()
	if err != nil {
		return Config{}, err
	}
	return LoadFrom(path)
}

// Save writes to the default config file location.
func (c Config) Save() error {
	path, err := configPath()
	if err != nil {
		return err
	}
	return c.SaveTo(path)
}
