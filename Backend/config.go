package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

func defaultConfig() Config {
	return Config{
		StaleAfterSeconds: 600,
		ClaudePollingMode: "inference",
		Claude:            ProviderConfig{RoutesEnabled: []Route{RouteKeychain}, KeychainPollIntervalSec: 60},
		Codex:             ProviderConfig{RoutesEnabled: []Route{RouteInjection}, KeychainPollIntervalSec: 60},
		Antigravity:       ProviderConfig{RoutesEnabled: []Route{RouteKeychain}, KeychainPollIntervalSec: 120},
	}
}

func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", "AIUsageWidget", "config.json"), nil
}

func loadConfig(path string) (Config, error) {
	cfg := defaultConfig()
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return cfg, err
	}
	return cfg, validateConfig(cfg)
}

func saveConfig(path string, cfg Config) error {
	if err := validateConfig(cfg); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return atomicPrivateWrite(path, b)
}

type partialConfig struct {
	StaleAfterSeconds *int64          `json:"staleAfterSeconds"`
	CollectionPaused  *bool           `json:"collectionPaused"`
	ClaudePollingMode *string         `json:"claude_polling_mode"`
	Claude            *ProviderConfig `json:"claude"`
	Codex             *ProviderConfig `json:"codex"`
	Antigravity       *ProviderConfig `json:"antigravity"`
}

func mergePartialConfig(current Config, patch partialConfig) (Config, error) {
	if patch.StaleAfterSeconds != nil {
		if *patch.StaleAfterSeconds <= 0 {
			return current, errors.New("staleAfterSeconds must be positive")
		}
		current.StaleAfterSeconds = *patch.StaleAfterSeconds
	}
	if patch.CollectionPaused != nil {
		current.CollectionPaused = *patch.CollectionPaused
	}
	if patch.ClaudePollingMode != nil {
		current.ClaudePollingMode = *patch.ClaudePollingMode
	}
	if patch.Claude != nil {
		current.Claude = *patch.Claude
	}
	if patch.Codex != nil {
		current.Codex = *patch.Codex
	}
	if patch.Antigravity != nil {
		current.Antigravity = *patch.Antigravity
	}
	return current, validateConfig(current)
}

func validateConfig(cfg Config) error {
	if cfg.StaleAfterSeconds < 0 {
		return errors.New("staleAfterSeconds must be nonnegative")
	}
	if cfg.ClaudePollingMode != "" && cfg.ClaudePollingMode != "inference" && cfg.ClaudePollingMode != "disabled" {
		return errors.New("claude_polling_mode must be inference or disabled")
	}
	if err := validateProviderConfig(ProviderClaude, cfg.Claude); err != nil {
		return err
	}
	if err := validateProviderConfig(ProviderCodex, cfg.Codex); err != nil {
		return err
	}
	return validateProviderConfig(ProviderAntigravity, cfg.Antigravity)
}

func validateProviderConfig(id ProviderID, pc ProviderConfig) error {
	if pc.NotifyThresholdPercent != nil && (*pc.NotifyThresholdPercent < 1 || *pc.NotifyThresholdPercent > 100) {
		return errors.New(string(id) + ": notify_threshold_percent must be between 1 and 100")
	}
	if pc.KeychainPollIntervalSec <= 0 {
		return errors.New(string(id) + ": keychain_poll_interval_sec must be positive")
	}
	seen := map[Route]bool{}
	for _, r := range pc.RoutesEnabled {
		if r != RouteKeychain && r != RouteInjection {
			return errors.New(string(id) + ": invalid route " + string(r))
		}
		if seen[r] {
			return errors.New(string(id) + ": duplicate route " + string(r))
		}
		seen[r] = true
	}
	return nil
}
