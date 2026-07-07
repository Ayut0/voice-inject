package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSaveLoadRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")

	cfg := Default()
	cfg.DefaultLanguage = Japanese
	cfg.MaxRecordDuration = 30 * time.Second

	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo: %v", err)
	}
	got, err := LoadFrom(path)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if got != cfg {
		t.Errorf("round trip mismatch:\n got  %+v\n want %+v", got, cfg)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("file mode = %o, want 600", perm)
	}
}

func TestSaveToEnforces600OnPreExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")

	// Create file with loose permissions (0644)
	if err := os.WriteFile(path, []byte("placeholder"), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	// Verify initial permissions are 0644
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat before: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o644 {
		t.Errorf("initial file mode = %o, want 644", perm)
	}

	// Save config to the same path
	cfg := Default()
	if err := cfg.SaveTo(path); err != nil {
		t.Fatalf("SaveTo: %v", err)
	}

	// Verify permissions are now 0600
	info, err = os.Stat(path)
	if err != nil {
		t.Fatalf("stat after: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("file mode = %o, want 600", perm)
	}
}

func TestLoadFromMissingFileReturnsDefaults(t *testing.T) {
	got, err := LoadFrom(filepath.Join(t.TempDir(), "nope.json"))
	if err != nil {
		t.Fatalf("LoadFrom missing file: %v", err)
	}
	if got != Default() {
		t.Errorf("got %+v, want Default()", got)
	}
}

func TestLoadFromCorruptFileReturnsError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadFrom(path); err == nil {
		t.Error("want error for corrupt config file")
	}
}

func TestApplyPatch(t *testing.T) {
	tests := []struct {
		name    string
		patch   string
		wantErr bool
		check   func(t *testing.T, c Config)
	}{
		{"change lang", `{"lang":"ja"}`, false, func(t *testing.T, c Config) {
			if c.DefaultLanguage != Japanese {
				t.Errorf("lang = %q, want ja", c.DefaultLanguage)
			}
			if c.MaxTextLength != Default().MaxTextLength {
				t.Error("untouched field changed")
			}
		}},
		{"change max duration", `{"maxRecordMs":30000}`, false, func(t *testing.T, c Config) {
			if c.MaxRecordDuration != 30*time.Second {
				t.Errorf("MaxRecordDuration = %v, want 30s", c.MaxRecordDuration)
			}
		}},
		{"invalid lang rejected", `{"lang":"xx"}`, true, nil},
		{"invalid json rejected", `{`, true, nil},
		{"minTextLength above maxTextLength rejected", `{"minTextLength":6000}`, true, nil},
		{"minTextLength equal to maxTextLength allowed", `{"minTextLength":5000}`, false, func(t *testing.T, c Config) {
			if c.MinTextLength != 5000 {
				t.Errorf("MinTextLength = %d, want 5000", c.MinTextLength)
			}
		}},
		{"unknown fields ignored", `{"bogus":true}`, false, func(t *testing.T, c Config) {
			if c != Default() {
				t.Error("config changed by unknown field")
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Default().ApplyPatch([]byte(tt.patch))
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if tt.check != nil {
				tt.check(t, got)
			}
		})
	}
}
