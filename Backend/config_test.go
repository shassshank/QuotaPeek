package main

import (
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

func TestValidateRejectsCodexKeychain(t *testing.T) {
	cfg := defaultConfig()
	cfg.Codex.RoutesEnabled = []Route{RouteKeychain}
	if err := validateConfig(cfg); err == nil {
		t.Fatal("validateConfig accepted codex keychain route")
	}
}
