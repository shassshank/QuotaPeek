package main

import (
	"sync"
	"time"
)

type Store struct {
	mu      sync.RWMutex
	cfg     Config
	samples map[ProviderID]map[Route]routeSample
	errors  []ErrorEntry
}

func NewStore(cfg Config) *Store {
	return &Store{
		cfg: cfg,
		samples: map[ProviderID]map[Route]routeSample{
			ProviderClaude:      {},
			ProviderCodex:       {},
			ProviderAntigravity: {},
		},
	}
}

func (s *Store) Config() Config {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg
}

func (s *Store) SetConfig(cfg Config) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg = cfg
}

func (s *Store) SetSample(provider ProviderID, route Route, data UsageData, asOf int64) {
	if data.empty() {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.samples[provider] == nil {
		s.samples[provider] = map[Route]routeSample{}
	}
	s.samples[provider][route] = routeSample{data: data, asOf: asOf}
}

func (s *Store) AddError(provider ProviderID, route Route, message string) {
	entry := ErrorEntry{Provider: provider, Route: route, Message: redactMessage(message), At: time.Now().Unix()}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.errors = append(s.errors, entry)
	if len(s.errors) > 200 {
		s.errors = append([]ErrorEntry(nil), s.errors[len(s.errors)-200:]...)
	}
}

func (s *Store) Errors(limit int) []ErrorEntry {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := len(s.errors)
	if limit > n {
		limit = n
	}
	out := make([]ErrorEntry, 0, limit)
	for i := n - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, s.errors[i])
	}
	return out
}

func (s *Store) Status(now int64) StatusResponse {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return StatusResponse{Providers: []ProviderStatus{
		s.providerStatusLocked(ProviderClaude, s.cfg.Claude, now),
		s.providerStatusLocked(ProviderCodex, s.cfg.Codex, now),
		s.providerStatusLocked(ProviderAntigravity, s.cfg.Antigravity, now),
	}}
}

func (s *Store) providerStatusLocked(id ProviderID, cfg ProviderConfig, now int64) ProviderStatus {
	sample, active := chooseSample(cfg, s.samples[id], now)
	var data *UsageData
	var asOf *int64
	if active != RouteNone {
		copyData := sample.data
		copyAsOf := sample.asOf
		data = &copyData
		asOf = &copyAsOf
	}
	// A one-off error (e.g. a request aborted by an unrelated config save) should
	// not permanently hide valid data once a later poll has succeeded - only
	// surface it if it happened after the sample currently being shown.
	lastErr := s.lastErrorLocked(id)
	if lastErr != nil && active != RouteNone && lastErr.At <= sample.asOf {
		lastErr = nil
	}
	return ProviderStatus{
		ID:            id,
		RoutesEnabled: append([]Route(nil), cfg.RoutesEnabled...),
		ActiveRoute:   active,
		Data:          data,
		AsOf:          asOf,
		LastError:     lastErr,
	}
}

func chooseSample(cfg ProviderConfig, samples map[Route]routeSample, now int64) (routeSample, Route) {
	if len(samples) == 0 {
		return routeSample{}, RouteNone
	}
	maxAge := int64(cfg.KeychainPollIntervalSec * 2)
	if maxAge < 600 {
		maxAge = 600
	}

	// Injection always wins over keychain when both are enabled and its sample is
	// fresh - preference is by freshness, not by routes_enabled array order (a user
	// enabling both routes via Settings should always get live data when it's
	// actually live, regardless of which order the toggles were flipped in).
	orderedRoutes := make([]Route, 0, len(cfg.RoutesEnabled))
	if hasRoute(cfg.RoutesEnabled, RouteInjection) {
		orderedRoutes = append(orderedRoutes, RouteInjection)
	}
	if hasRoute(cfg.RoutesEnabled, RouteKeychain) {
		orderedRoutes = append(orderedRoutes, RouteKeychain)
	}

	for _, route := range orderedRoutes {
		sample, ok := samples[route]
		if !ok || sample.data.empty() {
			continue
		}
		if route == RouteInjection && now-sample.asOf > maxAge {
			continue
		}
		return sample, route
	}

	// Nothing passed the freshness bar (e.g. Injection is the only route enabled
	// and its last push is older than maxAge, with no Keychain fallback to try
	// instead) - showing the most recent real sample we have beats showing
	// nothing; the UI already surfaces its age via "Updated X ago".
	var best routeSample
	bestRoute := RouteNone
	for _, route := range orderedRoutes {
		sample, ok := samples[route]
		if !ok || sample.data.empty() {
			continue
		}
		if bestRoute == RouteNone || sample.asOf > best.asOf {
			best = sample
			bestRoute = route
		}
	}
	return best, bestRoute
}

func (s *Store) lastErrorLocked(provider ProviderID) *ErrorEntry {
	for i := len(s.errors) - 1; i >= 0; i-- {
		if s.errors[i].Provider == provider {
			entry := s.errors[i]
			return &entry
		}
	}
	return nil
}
