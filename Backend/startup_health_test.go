package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestStartupHookMerge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	original := []byte(`{"other":{"keep":true},"statusLine":{"type":"command","command":"my-hook"}}`)
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	desired := map[string]any{"type": "command", "command": "python QuotaPeek/hook.py", "enabled": true, "refreshInterval": float64(3)}
	if err := mergeStatusline(path, desired); err != nil {
		t.Fatal(err)
	}
	backups, _ := filepath.Glob(path + ".bak.*")
	if len(backups) != 1 {
		t.Fatal(backups)
	}
	backup, _ := os.ReadFile(backups[0])
	if string(backup) != string(original) {
		t.Fatal("backup changed")
	}
	raw, _ := os.ReadFile(path)
	var data map[string]any
	if json.Unmarshal(raw, &data) != nil || data["other"] == nil {
		t.Fatal("lost unrelated key")
	}
	before, _ := os.Stat(path)
	if err := mergeStatusline(path, desired); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(path)
	if !os.SameFile(before, after) {
		t.Fatal("not idempotent")
	}
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := mergeStatusline(path, desired); err == nil {
		t.Fatal("invalid JSON replaced")
	}
}

func TestStartupChecksBothHooks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	bin := filepath.Join(home, "Library", "Application Support", "QuotaPeek", "bin")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	cfg := defaultConfig()
	cfg.Accounts = []AccountConfig{legacyAccount(ProviderAntigravity)}
	issues := checkStartupHooks(cfg)
	claude := filepath.Join(home, ".claude", "settings.json")
	if _, err := os.Stat(claude); !os.IsNotExist(err) {
		t.Fatal("created settings without hook")
	}
	if len(issues) != 2 {
		t.Fatalf("expected an issue for each missing hook script, got %v", issues)
	}
	for _, provider := range []string{"claude", "antigravity"} {
		if err := os.WriteFile(filepath.Join(bin, provider+"-statusline-hook.py"), []byte("# hook"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if issues := checkStartupHooks(cfg); len(issues) != 0 {
		t.Fatalf("expected no issues once hooks exist, got %v", issues)
	}
	for _, path := range []string{claude, filepath.Join(home, ".gemini", "antigravity-cli", "settings.json")} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal(err)
		}
	}
}

func TestCheckCLIBinariesReportsMissingBinary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	emptyPathDir := t.TempDir()
	t.Setenv("PATH", emptyPathDir)

	cfg := defaultConfig()
	issues := checkCLIBinaries(cfg)
	if len(issues) != 2 {
		t.Fatalf("expected claude and codex to be reported missing, got %v", issues)
	}
	for _, issue := range issues {
		if issue.provider != ProviderClaude && issue.provider != ProviderCodex {
			t.Fatalf("unexpected provider in issue: %+v", issue)
		}
	}

	// Antigravity isn't configured, so it shouldn't be checked (and reported)
	// even though agy is equally unresolvable on this empty PATH.
	for _, issue := range issues {
		if issue.provider == ProviderAntigravity {
			t.Fatal("antigravity should not be checked when not configured")
		}
	}
}

func TestCheckCLIBinariesResolvesFromPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	binDir := t.TempDir()
	for _, name := range []string{"claude", "codex"} {
		p := filepath.Join(binDir, name)
		if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", binDir)

	if issues := checkCLIBinaries(defaultConfig()); len(issues) != 0 {
		t.Fatalf("expected both binaries resolvable via PATH, got %v", issues)
	}
}

func TestRunSetupHealthCheckRecordsAccountVisibleError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", t.TempDir())

	cfg := defaultConfig()
	store := NewStore(cfg)
	runSetupHealthCheck(cfg, store)

	errs := store.Errors(50)
	if len(errs) == 0 {
		t.Fatal("expected setup issues to surface as account-visible errors")
	}
	foundClaude := false
	for _, e := range errs {
		if e.Provider == ProviderClaude {
			foundClaude = true
		}
	}
	if !foundClaude {
		t.Fatalf("expected a claude CLI issue among errors, got %+v", errs)
	}
}
