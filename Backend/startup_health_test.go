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
	checkStartupHooks(cfg)
	claude := filepath.Join(home, ".claude", "settings.json")
	if _, err := os.Stat(claude); !os.IsNotExist(err) {
		t.Fatal("created settings without hook")
	}
	for _, provider := range []string{"claude", "antigravity"} {
		if err := os.WriteFile(filepath.Join(bin, provider+"-statusline-hook.py"), []byte("# hook"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	checkStartupHooks(cfg)
	for _, path := range []string{claude, filepath.Join(home, ".gemini", "antigravity-cli", "settings.json")} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal(err)
		}
	}
}
