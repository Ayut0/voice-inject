package config

import (
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
