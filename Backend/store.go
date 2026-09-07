package main

import (
	"log"
	"sync"
	"time"
)

type providerHealth struct {
	success *int64
	failure *int64
	message *string
}

type Store struct {
	persistencePath string
	history         map[ProviderID]map[Route][]HistoryPoint
	collectionMu    sync.RWMutex
	resetting       map[ProviderID]bool
	health          map[ProviderID]providerHealth
	mu              sync.RWMutex
	cfg             Config
	samples         map[ProviderID]map[Route]routeSample
	errors          []ErrorEntry
	inFlight        map[string]bool
}

func NewStore(cfg Config) *Store {
	return &Store{
		cfg:       cfg,
		history:   make(map[ProviderID]map[Route][]HistoryPoint),
		resetting: make(map[ProviderID]bool),
		health:    make(map[ProviderID]providerHealth),
		inFlight:  make(map[string]bool),
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
	// Drain active polls before publishing pause; block new poll admissions.
	s.collectionMu.Lock()
	defer s.collectionMu.Unlock()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg = cfg
}

func (s *Store) SetSample(provider ProviderID, route Route, data UsageData, asOf int64) {
	s.SetSampleAt(provider, route, data, time.Unix(asOf, 0))
}

func (s *Store) SetSampleAt(provider ProviderID, route Route, data UsageData, started time.Time) {
	if !validSampleKey(provider, route) || data.quotaEmpty() || !validUsage(data) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.samples[provider] == nil {
		s.samples[provider] = map[Route]routeSample{}
	}
	if old, ok := s.samples[provider][route]; ok && started.Before(old.started) {
		return
	}
	s.samples[provider][route] = routeSample{data: data, asOf: started.Unix(), started: started}
	if s.history[provider] == nil {
		s.history[provider] = make(map[Route][]HistoryPoint)
	}
	percent := data.UsedPercent5H
	if percent == nil {
		percent = data.UsedPercentWeekly
	}
	if percent != nil {
		s.history[provider][route] = append(s.history[provider][route], HistoryPoint{At: started.Unix(), UsedPercent: *percent})
	}
	s.pruneHistoryLocked(time.Now().Unix())
	if err := s.persistLocked(); err != nil {
		log.Printf("sample persistence failed: %v", err)
	}
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
	sample, active := chooseSample(cfg, s.samples[id], now, s.cfg.StaleAfterSeconds)
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
	errorRoute := active
	if errorRoute == RouteNone {
		if hasRoute(cfg.RoutesEnabled, RouteInjection) {
			errorRoute = RouteInjection
		} else if hasRoute(cfg.RoutesEnabled, RouteKeychain) {
			errorRoute = RouteKeychain
		}
	}
	lastErr := s.lastErrorLocked(id, errorRoute)
	if lastErr != nil && active != RouteNone && lastErr.At <= sample.asOf {
		lastErr = nil
	}
	h := s.health[id]
	return ProviderStatus{
		CredentialSource: "unknown",
		RestoredFromDisk: active != RouteNone && sample.restored,
		LastSuccessAt:    h.success, LastFailureAt: h.failure, LastErrorMessage: h.message,
		ID:            id,
		RoutesEnabled: append([]Route{}, cfg.RoutesEnabled...),
		ActiveRoute:   active,
		Data:          data,
		AsOf:          asOf,
		LastError:     lastErr,
	}
}

func chooseSample(cfg ProviderConfig, samples map[Route]routeSample, now int64, staleAfter ...int64) (routeSample, Route) {
	if len(samples) == 0 {
		return routeSample{}, RouteNone
	}
	maxAge := sampleMaxAge(cfg, staleAfter...)

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
		if !ok || sample.data.quotaEmpty() {
			continue
		}
		if sample.restored || now-sample.asOf > maxAge {
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
		if !ok || sample.data.quotaEmpty() {
			continue
		}
		if bestRoute == RouteNone || sample.asOf > best.asOf {
			best = sample
			bestRoute = route
		}
	}
	return best, bestRoute
}

func (s *Store) lastErrorLocked(provider ProviderID, route Route) *ErrorEntry {
	for i := len(s.errors) - 1; i >= 0; i-- {
		if s.errors[i].Provider == provider && s.errors[i].Route == route && route != RouteNone {
			entry := s.errors[i]
			return &entry
		}
	}
	return nil
}

// RouteFresh reports on the requested route even when it is disabled or another
// route is displayed. Unlike chooseSample, it never falls back to stale data.
func (s *Store) RouteFresh(provider ProviderID, route Route, now int64) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	cfg := s.cfg.Claude
	switch provider {
	case ProviderCodex:
		cfg = s.cfg.Codex
	case ProviderAntigravity:
		cfg = s.cfg.Antigravity
	}
	sample, ok := s.samples[provider][route]
	return ok && !sample.restored && !sample.data.quotaEmpty() && now-sample.asOf <= sampleMaxAge(cfg, s.cfg.StaleAfterSeconds)
}

func sampleMaxAge(cfg ProviderConfig, staleAfter ...int64) int64 {
	age := int64(600)
	if len(staleAfter) > 0 && staleAfter[0] > 0 {
		age = staleAfter[0]
	}
	// Saturate rather than overflow for unusually large configured intervals.
	interval := int64(cfg.KeychainPollIntervalSec)
	if interval > (1<<63-1)/2 {
		return 1<<63 - 1
	}
	return max(interval*2, age)
}

// Shared by scheduled polls, refreshes and diagnostic requests.
func (s *Store) beginPoll(provider ProviderID, route Route) (time.Time, bool) {
	s.collectionMu.RLock()
	s.mu.Lock()
	defer s.mu.Unlock()
	key := string(provider) + ":" + string(route)
	if s.cfg.CollectionPaused || s.resetting[provider] || s.inFlight[key] {
		s.collectionMu.RUnlock()
		return time.Time{}, false
	}
	s.inFlight[key] = true
	return time.Now(), true
}
func (s *Store) endPoll(provider ProviderID, route Route) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.inFlight, string(provider)+":"+string(route))
	s.collectionMu.RUnlock()
}

// Reserve both routes atomically, including while collection is paused.
func (s *Store) beginCredentialReset(provider ProviderID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.resetting[provider] || s.inFlight[string(provider)+":"+string(RouteKeychain)] || s.inFlight[string(provider)+":"+string(RouteInjection)] {
		return false
	}
	s.resetting[provider] = true
	return true
}
func (s *Store) endCredentialReset(provider ProviderID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.resetting, provider)
}

// Poll health is independent of route selection, sample freshness and the error
// ring. Historical failures remain available after recovery and ring eviction.
func (s *Store) recordPoll(provider ProviderID, data UsageData, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	at := time.Now().Unix()
	h := s.health[provider]
	if err != nil || data.quotaEmpty() {
		message := "Fetch returned no quota data."
		if err != nil {
			message = redactMessage(err.Error())
		}
		h.failure, h.message = &at, &message
	} else {
		h.success = &at
	}
	s.health[provider] = h
}
