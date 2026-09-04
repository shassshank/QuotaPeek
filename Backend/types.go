package main

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
	ID            ProviderID  `json:"id"`
	RoutesEnabled []Route     `json:"routes_enabled"`
	ActiveRoute   Route       `json:"active_route"`
	Data          *UsageData  `json:"data"`
	AsOf          *int64      `json:"as_of"`
	LastError     *ErrorEntry `json:"last_error"`
}

type StatusResponse struct {
	Providers []ProviderStatus `json:"providers"`
}

type ProviderConfig struct {
	RoutesEnabled           []Route `json:"routes_enabled"`
	KeychainPollIntervalSec int     `json:"keychain_poll_interval_sec"`
}

type Config struct {
	Claude      ProviderConfig `json:"claude"`
	Codex       ProviderConfig `json:"codex"`
	Antigravity ProviderConfig `json:"antigravity"`
}

type routeSample struct {
	data UsageData
	asOf int64
}
