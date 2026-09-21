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

// setupIssue is a specific, user-facing description of something the setup
// health check found broken and could not fix itself - surfaced via
// Store.AddError so it shows up in the app's Account Health tab instead of
// only ever appearing in daemon.log.
type setupIssue struct {
	provider ProviderID
	message  string
}

// checkStartupHooks verifies the statusline hooks CLI updates are prone to
// silently reverting (an agent CLI reinstall/update commonly rewrites its own
// settings.json, wiping the statusLine block QuotaPeek relies on to receive
// live usage data) and re-merges QuotaPeek's entry back in when that
// happened. Returns any issue it found but could not repair itself, such as
// a hook script that's gone missing (that needs a QuotaPeek reinstall, not
// just a settings merge).
func checkStartupHooks(cfg Config) []setupIssue {
	var issues []setupIssue
	home, err := os.UserHomeDir()
	if err != nil {
		log.Printf("startup health: %v", err)
		return issues
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		log.Printf("startup health: python3 unavailable: %v", err)
		issues = append(issues, setupIssue{provider: ProviderClaude, message: "python3 not found on PATH - statusline hooks can't run; install Python 3 or check PATH"})
		return issues
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
		providerID := ProviderClaude
		if provider == "antigravity" {
			providerID = ProviderAntigravity
		}
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
			issues = append(issues, setupIssue{provider: providerID, message: fmt.Sprintf("statusline hook script missing at %s - reinstall QuotaPeek to restore it", script)})
			continue
		}
		if err := mergeStatusline(settings, desired); err != nil {
			log.Printf("startup health: %s: %v", settings, err)
			issues = append(issues, setupIssue{provider: providerID, message: fmt.Sprintf("couldn't repair %s: %v", settings, err)})
		}
	}
	return issues
}

// checkCLIBinaries verifies the CLI binaries the daemon shells out to
// (session-refresh triggers, Antigravity OAuth client discovery) are still
// resolvable. An agent CLI update that moves, renames, or uninstalls its own
// binary breaks these silently - there's nothing to auto-repair here (unlike
// the statusline merge above), so any miss is just reported.
func checkCLIBinaries(cfg Config) []setupIssue {
	var issues []setupIssue
	if issue := checkBinResolvable(ProviderClaude, claudeBin()); issue != nil {
		issues = append(issues, *issue)
	}
	if issue := checkBinResolvable(ProviderCodex, codexBin()); issue != nil {
		issues = append(issues, *issue)
	}
	antigravity := len(cfg.Antigravity.RoutesEnabled) > 0
	for _, a := range cfg.Accounts {
		if a.Provider == ProviderAntigravity {
			antigravity = true
		}
	}
	if antigravity {
		if _, err := locateAntigravityBinary(); err != nil {
			issues = append(issues, setupIssue{provider: ProviderAntigravity, message: fmt.Sprintf("antigravity CLI (agy) not found: %v - reinstall Antigravity or make sure agy is on PATH", err)})
		}
	}
	return issues
}

func checkBinResolvable(provider ProviderID, bin string) *setupIssue {
	if strings.ContainsRune(bin, os.PathSeparator) {
		if info, err := os.Stat(bin); err != nil || info.IsDir() {
			return &setupIssue{provider: provider, message: fmt.Sprintf("%s CLI expected at %s but it's missing - reinstall the %s CLI", provider, bin, provider)}
		}
		return nil
	}
	if _, err := exec.LookPath(bin); err != nil {
		return &setupIssue{provider: provider, message: fmt.Sprintf("%s CLI (%q) not found on PATH - install it or update PATH", provider, bin)}
	}
	return nil
}

// runSetupHealthCheck runs every setup health check, logs what it finds, and
// records anything it couldn't fix itself as an account-visible error so a
// broken update surfaces as a specific message in Settings rather than
// silent, unexplained "no data" in the tray.
func runSetupHealthCheck(cfg Config, store *Store) {
	issues := append(checkStartupHooks(cfg), checkCLIBinaries(cfg)...)
	for _, issue := range issues {
		log.Printf("setup health: %s", issue.message)
		if store != nil {
			store.AddError(issue.provider, RouteInjection, issue.message)
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
