package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"time"
)

const historyLimit = 200
const historyMaxAge int64 = 24 * 60 * 60

type HistoryPoint struct {
	At          int64   `json:"at"`
	UsedPercent float64 `json:"usedPercent"`
}

type persistedSample struct {
	AccountID string         `json:"accountId,omitempty"`
	Provider  ProviderID     `json:"provider"`
	Route     Route          `json:"route"`
	Data      UsageData      `json:"data"`
	Started   time.Time      `json:"started"`
	Points    []HistoryPoint `json:"points"`
}
type sampleSnapshot struct {
	Version int               `json:"version"`
	Samples []persistedSample `json:"samples"`
}

func validSampleKey(p ProviderID, r Route) bool {
	return (p == ProviderClaude || p == ProviderCodex || p == ProviderAntigravity) && (r == RouteKeychain || r == RouteInjection)
}
func validUsage(d UsageData) bool {
	for _, v := range []*float64{d.UsedPercent5H, d.UsedPercentWeekly, d.UsedPercentWeeklyClaude, d.UsedPercentWeeklyGPT, d.ContextWindowUsedPercent} {
		if v != nil && (math.IsNaN(*v) || math.IsInf(*v, 0) || *v < 0 || *v > 100) {
			return false
		}
	}
	return true
}

// Called before polling starts. A missing/corrupt cache does not prevent future
// writes; decode and validate the entire snapshot before publishing any of it.
func (s *Store) enablePersistence(path string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.persistencePath = path
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var snapshot sampleSnapshot
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		return err
	}
	if snapshot.Version != 1 && snapshot.Version != 2 {
		return fmt.Errorf("unsupported sample snapshot version %d", snapshot.Version)
	}
	seen := make(map[string]bool)
	for _, item := range snapshot.Samples {
		key := item.AccountID + ":" + string(item.Provider) + ":" + string(item.Route)
		if !validSampleKey(item.Provider, item.Route) || !validUsage(item.Data) || item.Data.quotaEmpty() || item.Started.IsZero() || seen[key] {
			return fmt.Errorf("invalid persisted sample")
		}
		seen[key] = true
		var previous int64
		for i, p := range item.Points {
			if math.IsNaN(p.UsedPercent) || math.IsInf(p.UsedPercent, 0) || p.UsedPercent < 0 || p.UsedPercent > 100 || (i > 0 && p.At < previous) || p.At > item.Started.Unix() {
				return fmt.Errorf("invalid persisted history")
			}
			previous = p.At
		}
	}
	for _, item := range snapshot.Samples {
		key := item.Provider
		if item.AccountID != "" {
			key = ProviderID(item.AccountID)
			if s.providerLocked(key) == key {
				continue
			}
		} else {
			key = s.keyLocked(key)
		}
		if s.samples[key] == nil {
			s.samples[key] = map[Route]routeSample{}
		}
		s.samples[key][item.Route] = routeSample{data: item.Data, asOf: item.Started.Unix(), started: item.Started, restored: true}
		if s.history[key] == nil {
			s.history[key] = make(map[Route][]HistoryPoint)
		}
		s.history[key][item.Route] = item.Points
	}
	s.pruneHistoryLocked(time.Now().Unix())
	return nil
}

func boundedHistory(points []HistoryPoint, now int64) []HistoryPoint {
	first := 0
	for first < len(points) && points[first].At < now-historyMaxAge {
		first++
	}
	if len(points)-first > historyLimit {
		first = len(points) - historyLimit
	}
	return append([]HistoryPoint{}, points[first:]...)
}
func (s *Store) pruneHistoryLocked(now int64) {
	for _, routes := range s.history {
		for route, points := range routes {
			routes[route] = boundedHistory(points, now)
		}
	}
}
func (s *Store) History(provider ProviderID, route Route, now int64) []HistoryPoint {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return boundedHistory(s.history[s.keyLocked(provider)][route], now)
}

// Serialize writes under the store lock so an older snapshot cannot win a race.
// Each accepted sample is durable before SetSampleAt returns on successful IO.
func (s *Store) persistLocked() error {
	if s.persistencePath == "" {
		return nil
	}
	snapshot := sampleSnapshot{Version: 2}
	for provider, routes := range s.samples {
		for route, sample := range routes {
			accountID := ""
			if s.providerLocked(provider) != provider {
				accountID = string(provider)
			}
			snapshot.Samples = append(snapshot.Samples, persistedSample{AccountID: accountID, Provider: s.providerLocked(provider), Route: route, Data: sample.data, Started: sample.started, Points: s.history[provider][route]})
		}
	}
	raw, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	return atomicPrivateWrite(s.persistencePath, raw)
}
