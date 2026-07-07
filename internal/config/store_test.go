package config

import (
	"errors"
	"sync"
	"testing"
)

func TestStoreGetSet(t *testing.T) {
	s := NewStore(Default())
	if got := s.Get(); got != Default() {
		t.Errorf("initial Get = %+v, want Default()", got)
	}
	updated := Default()
	updated.DefaultLanguage = Japanese
	s.Set(updated)
	if got := s.Get(); got.DefaultLanguage != Japanese {
		t.Errorf("after Set, lang = %q, want ja", got.DefaultLanguage)
	}
}

func TestStoreConcurrentAccess(t *testing.T) {
	// Run with -race; fails on a data race.
	s := NewStore(Default())
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); s.Set(Default()) }()
		go func() { defer wg.Done(); _ = s.Get() }()
	}
	wg.Wait()
}

func TestStoreMutateIsAtomic(t *testing.T) {
	// Regression test: concurrent Get-then-Set pairs (the pre-fix setConfig
	// pattern) lose updates under -race; Mutate must not.
	s := NewStore(Default())
	const n = 100
	var wg sync.WaitGroup
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			if _, err := s.Mutate(func(c Config) (Config, error) {
				c.MinTextLength++
				return c, nil
			}); err != nil {
				t.Errorf("Mutate: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := s.Get().MinTextLength; got != Default().MinTextLength+n {
		t.Errorf("MinTextLength = %d, want %d (lost update)", got, Default().MinTextLength+n)
	}
}

func TestStoreMutateErrorLeavesUnchanged(t *testing.T) {
	s := NewStore(Default())
	wantErr := errors.New("boom")
	_, err := s.Mutate(func(c Config) (Config, error) {
		return Config{}, wantErr
	})
	if err != wantErr {
		t.Fatalf("err = %v, want %v", err, wantErr)
	}
	if got := s.Get(); got != Default() {
		t.Errorf("store mutated despite fn error: %+v", got)
	}
}
