package main

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"testing"
)

func TestConfigLoadSaveRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	cfg := Config{
		Claude:      ProviderConfig{RoutesEnabled: []Route{RouteKeychain, RouteInjection}, KeychainPollIntervalSec: 61},
		Codex:       ProviderConfig{RoutesEnabled: []Route{RouteInjection}, KeychainPollIntervalSec: 62},
		Antigravity: ProviderConfig{RoutesEnabled: []Route{RouteKeychain}, KeychainPollIntervalSec: 63},
	}
	if err := saveConfig(path, cfg); err != nil {
		t.Fatal(err)
	}
	got, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, cfg) {
		t.Fatalf("roundtrip = %#v, want %#v", got, cfg)
	}
}

func TestValidateAcceptsCodexKeychain(t *testing.T) {
	cfg := defaultConfig()
	cfg.Codex.RoutesEnabled = []Route{RouteKeychain}
	if err := validateConfig(cfg); err != nil {
		t.Fatalf("validateConfig rejected codex keychain route: %v", err)
	}
}

func TestNotifyThresholdMergeSaveLoad(t *testing.T) {
	for _, threshold := range []int{1, 80, 100} {
		var patch partialConfig
		raw := fmt.Sprintf(`{"claude":{"routes_enabled":["keychain"],"keychain_poll_interval_sec":60,"notify_threshold_percent":%d}}`, threshold)
		if err := json.Unmarshal([]byte(raw), &patch); err != nil {
			t.Fatal(err)
		}
		cfg, err := mergePartialConfig(defaultConfig(), patch)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(t.TempDir(), "config.json")
		if err := saveConfig(path, cfg); err != nil {
			t.Fatal(err)
		}
		got, err := loadConfig(path)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got, cfg) || got.Claude.NotifyThresholdPercent == nil || *got.Claude.NotifyThresholdPercent != threshold {
			t.Fatalf("roundtrip = %+v", got)
		}
		for _, disabled := range []string{"", `,"notify_threshold_percent":null`} {
			raw := `{"claude":{"routes_enabled":["keychain"],"keychain_poll_interval_sec":60` + disabled + `}}`
			var clear partialConfig
			if err := json.Unmarshal([]byte(raw), &clear); err != nil {
				t.Fatal(err)
			}
			cleared, err := mergePartialConfig(got, clear)
			if err != nil {
				t.Fatal(err)
			}
			if err := saveConfig(path, cleared); err != nil {
				t.Fatal(err)
			}
			loaded, err := loadConfig(path)
			if err != nil || loaded.Claude.NotifyThresholdPercent != nil {
				t.Fatalf("disable roundtrip: %+v, %v", loaded, err)
			}
		}
	}
}

func TestNotifyThresholdValidation(t *testing.T) {
	for _, value := range []int{-1, 0, 101} {
		for _, provider := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
			pc := defaultConfig().Claude
			pc.NotifyThresholdPercent = &value
			if err := validateProviderConfig(provider, pc); err == nil {
				t.Fatalf("accepted %s threshold %d", provider, value)
			}
		}
	}
}

func TestNotifyThresholdPreservedAcrossProviderMerge(t *testing.T) {
	for _, threshold := range []int{1, 100} {
		cfg := defaultConfig()
		pc := cfg.Claude
		pc.NotifyThresholdPercent = &threshold
		merged, err := mergePartialConfig(cfg, partialConfig{Claude: &pc})
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(t.TempDir(), "config.json")
		if err := saveConfig(path, merged); err != nil {
			t.Fatal(err)
		}
		loaded, err := loadConfig(path)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(loaded, merged) {
			t.Fatalf("roundtrip: %+v", loaded)
		}
		other := loaded.Codex
		other.KeychainPollIntervalSec = 90
		preserved, err := mergePartialConfig(loaded, partialConfig{Codex: &other})
		if err != nil || *preserved.Claude.NotifyThresholdPercent != threshold {
			t.Fatalf("merge lost threshold: %+v %v", preserved, err)
		}
		pc.NotifyThresholdPercent = nil
		disabled, err := mergePartialConfig(preserved, partialConfig{Claude: &pc})
		if err != nil || disabled.Claude.NotifyThresholdPercent != nil {
			t.Fatal("did not disable notifications")
		}
		if err := saveConfig(path, disabled); err != nil {
			t.Fatal(err)
		}
		loaded, err = loadConfig(path)
		if err != nil || loaded.Claude.NotifyThresholdPercent != nil {
			t.Fatal("disabled threshold did not persist")
		}
	}
}

func TestNotifyThresholdRejectsOutOfRange(t *testing.T) {
	for _, threshold := range []int{-1, 0, 101} {
		for _, provider := range []ProviderID{ProviderClaude, ProviderCodex, ProviderAntigravity} {
			cfg := defaultConfig()
			pc := cfg.Claude
			pc.NotifyThresholdPercent = &threshold
			patch := partialConfig{}
			switch provider {
			case ProviderClaude:
				patch.Claude = &pc
			case ProviderCodex:
				patch.Codex = &pc
			case ProviderAntigravity:
				patch.Antigravity = &pc
			}
			invalid, err := mergePartialConfig(cfg, patch)
			if err == nil {
				t.Fatalf("accepted %d for %s", threshold, provider)
			}
			if err := saveConfig(filepath.Join(t.TempDir(), "config.json"), invalid); err == nil {
				t.Fatal("saved invalid threshold")
			}
		}
	}
}
