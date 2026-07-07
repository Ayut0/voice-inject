package config

import "sync"

// Store guards a Config for concurrent access: the daemon reads it per
// recording, the IPC handler writes it on setConfig.
type Store struct {
	mu  sync.RWMutex
	cfg Config
}

func NewStore(cfg Config) *Store {
	return &Store{cfg: cfg}
}

func (s *Store) Get() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg
}

func (s *Store) Set(cfg Config) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg = cfg
}

// Mutate atomically applies fn to the current config and stores the result.
// fn returning an error leaves the store unchanged, so concurrent callers
// (e.g. two setConfig commands) can't race a Get/Set pair and lose an update.
func (s *Store) Mutate(fn func(Config) (Config, error)) (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	updated, err := fn(s.cfg)
	if err != nil {
		return Config{}, err
	}
	s.cfg = updated
	return updated, nil
}
