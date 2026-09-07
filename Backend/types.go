package main

import "time"

type Route string

const (
	RouteKeychain  Route = "keychain"
	RouteInjection Route = "injection"
	RouteNone      Route = "none"
)

type ProviderID string

const (
	ProviderClaude      ProviderID = "claude"
	ProviderCodex       ProviderID = "codex"
	ProviderAntigravity ProviderID = "antigravity"
)

type UsageData struct {
	UsedPercent5H            *float64 `json:"used_percent_5h"`
	ResetsAt5H               *int64   `json:"resets_at_5h"`
	UsedPercentWeekly        *float64 `json:"used_percent_weekly"`
	ResetsAtWeekly           *int64   `json:"resets_at_weekly"`
	ContextWindowUsedPercent *float64 `json:"context_window_used_percent"`
}

func (u UsageData) empty() bool {
	return u.UsedPercent5H == nil &&
		u.ResetsAt5H == nil &&
		u.UsedPercentWeekly == nil &&
		u.ResetsAtWeekly == nil &&
		u.ContextWindowUsedPercent == nil
}

type ErrorEntry struct {
	Provider ProviderID `json:"provider"`
	Route    Route      `json:"route"`
	Message  string     `json:"message"`
	At       int64      `json:"at"`
}

type ProviderStatus struct {
	RestoredFromDisk bool        `json:"restoredFromDisk"`
	CredentialSource string      `json:"credentialSource"`
	EffectiveAccount *string     `json:"effectiveAccount"`
	LastSuccessAt    *int64      `json:"lastSuccessAt"`
	LastFailureAt    *int64      `json:"lastFailureAt"`
	LastErrorMessage *string     `json:"lastError"`
	ID               ProviderID  `json:"id"`
	RoutesEnabled    []Route     `json:"routes_enabled"`
	ActiveRoute      Route       `json:"active_route"`
	Data             *UsageData  `json:"data"`
	AsOf             *int64      `json:"as_of"`
	LastError        *ErrorEntry `json:"last_error"`
}

type StatusResponse struct {
	Providers []ProviderStatus `json:"providers"`
}

type ProviderConfig struct {
	NotifyThresholdPercent  *int    `json:"notify_threshold_percent,omitempty"`
	RoutesEnabled           []Route `json:"routes_enabled"`
	KeychainPollIntervalSec int     `json:"keychain_poll_interval_sec"`
}

type Config struct {
	StaleAfterSeconds int64          `json:"staleAfterSeconds"`
	CollectionPaused  bool           `json:"collectionPaused"`
	ClaudePollingMode string         `json:"claude_polling_mode"`
	Claude            ProviderConfig `json:"claude"`
	Codex             ProviderConfig `json:"codex"`
	Antigravity       ProviderConfig `json:"antigravity"`
}

type routeSample struct {
	restored bool
	data     UsageData
	asOf     int64
	started  time.Time
}

// Context usage alone cannot replace a provider's quota snapshot.
func (u UsageData) quotaEmpty() bool {
	return u.UsedPercent5H == nil && u.ResetsAt5H == nil &&
		u.UsedPercentWeekly == nil && u.ResetsAtWeekly == nil
}
