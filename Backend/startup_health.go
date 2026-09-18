package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"time"
)

func checkStartupHooks(cfg Config) {
	home, err := os.UserHomeDir()
	if err != nil {
		log.Printf("startup health: %v", err)
		return
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		log.Printf("startup health: python3 unavailable: %v", err)
		return
	}
	providers := []string{"claude"}
	antigravity := len(cfg.Antigravity.RoutesEnabled) > 0
	for _, a := range cfg.Accounts {
		if a.Provider == ProviderAntigravity {
			antigravity = true
		}
	}
	if antigravity {
		providers = append(providers, "antigravity")
	}
	for _, provider := range providers {
		script := filepath.Join(home, "Library", "Application Support", "QuotaPeek", "bin", provider+"-statusline-hook.py")
		settings := filepath.Join(home, ".claude", "settings.json")
		desired := map[string]any{"type": "command", "command": shellQuote(python) + " " + shellQuote(script), "enabled": true}
		if provider == "claude" {
			desired["refreshInterval"] = float64(3)
		} else {
			settings = filepath.Join(home, ".gemini", "antigravity-cli", "settings.json")
		}
		if info, err := os.Stat(script); err != nil || !info.Mode().IsRegular() {
			log.Printf("startup health: missing hook %s", script)
			continue
		}
		if err := mergeStatusline(settings, desired); err != nil {
			log.Printf("startup health: %s: %v", settings, err)
		}
	}
}

func shellQuote(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "$", `\$`, "`", "\\`").Replace(s) + `"`
}

// Match the installer's merge, backing up another status line before replacement.
func mergeStatusline(path string, desired map[string]any) error {
	raw, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	data := map[string]any{}
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &data); err != nil {
			return fmt.Errorf("invalid settings; left unchanged: %w", err)
		}
		if data == nil {
			return errors.New("settings must be an object")
		}
	}
	existing, ok := data["statusLine"].(map[string]any)
	matches := ok
	for key, value := range desired {
		if !reflect.DeepEqual(existing[key], value) {
			matches = false
		}
	}
	if matches {
		return nil
	}
	command, _ := existing["command"].(string)
	ours := ok && existing["type"] == "command" && strings.Contains(command, "QuotaPeek")
	if _, exists := data["statusLine"]; exists && !ours {
		backup := path + ".bak." + time.Now().Format("20060102T150405.000000000")
		if err := atomicPrivateWrite(backup, raw); err != nil {
			return err
		}
	}
	data["statusLine"] = desired
	out, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return atomicPrivateWrite(path, append(out, '\n'))
}
