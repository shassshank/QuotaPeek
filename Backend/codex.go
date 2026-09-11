package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

type codexRPCResponse struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

func FetchCodex(ctx context.Context) (UsageData, error) {
	return FetchCodexAt(ctx, defaultDir(ProviderCodex))
}

// FetchCodexAtCached returns a cached result from a previous FetchCodexAt call
// when available, avoiding a subprocess spawn on every poll tick.
func (c *Collector) FetchCodexAtCached(ctx context.Context, configDir string) (UsageData, error) {
	if data, ok := c.codexCache.get(configDir); ok {
		return data, nil
	}
	data, err := FetchCodexAt(ctx, configDir)
	if err != nil {
		return data, err
	}
	c.codexCache.put(configDir, data)
	return data, nil
}
func FetchCodexAt(ctx context.Context, configDir string) (UsageData, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, codexBin(), "app-server")
	cmd.Env = collectorEnv(withConfigDir(ctx, "CODEX_HOME", configDir))
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return UsageData{}, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return UsageData{}, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return UsageData{}, err
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	responses := map[int]codexRPCResponse{}
	var mu sync.Mutex
	done := make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(stdout)
		scanner.Buffer(make([]byte, 0, 4096), 1024*1024)
		for scanner.Scan() {
			var resp codexRPCResponse
			if err := json.Unmarshal(scanner.Bytes(), &resp); err == nil && resp.ID != 0 {
				mu.Lock()
				responses[resp.ID] = resp
				mu.Unlock()
			}
		}
	}()

	enc := json.NewEncoder(stdin)
	if err := enc.Encode(map[string]any{"id": 1, "method": "initialize", "params": map[string]any{"clientInfo": map[string]string{"name": "aiusagewidget", "version": "0.1.0"}}}); err != nil {
		return UsageData{}, err
	}
	if err := enc.Encode(map[string]any{"id": 2, "method": "account/rateLimits/read", "params": nil}); err != nil {
		return UsageData{}, err
	}

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return UsageData{}, errors.New("codex app-server timed out")
		case <-done:
			return UsageData{}, errors.New("codex app-server closed before rate-limit response")
		case <-ticker.C:
			mu.Lock()
			resp, ok := responses[2]
			mu.Unlock()
			if !ok {
				continue
			}
			if len(resp.Error) > 0 && string(resp.Error) != "null" {
				return UsageData{}, errors.New("codex RPC error: " + redactMessage(string(resp.Error)))
			}
			return ParseCodexRateLimits(resp.Result)
		}
	}
}

func ParseCodexRateLimits(raw json.RawMessage) (UsageData, error) {
	var root struct {
		RateLimits map[string]any `json:"rateLimits"`
	}
	if err := json.Unmarshal(raw, &root); err != nil {
		return UsageData{}, err
	}
	if root.RateLimits == nil {
		return UsageData{}, errors.New("codex response had no rateLimits")
	}
	data := UsageData{}
	assignCodexWindow(&data, root.RateLimits["primary"], "primary")
	assignCodexWindow(&data, root.RateLimits["secondary"], "secondary")
	if data.empty() {
		return UsageData{}, errors.New("codex response had no parseable windows")
	}
	return data, nil
}

func assignCodexWindow(data *UsageData, value any, fallback string) {
	entry, ok := value.(map[string]any)
	if !ok {
		return
	}
	used, usedOK := numberFromAny(entry["usedPercent"])
	reset, resetOK := numberFromAny(entry["resetsAt"])
	if !usedOK {
		return
	}
	window := ""
	if mins, ok := numberFromAny(entry["windowDurationMins"]); ok {
		switch int(mins) {
		case 300:
			window = "5h"
		case 10080:
			window = "weekly"
		}
	}
	if window == "" {
		window = map[string]string{"primary": "5h", "secondary": "weekly"}[fallback]
	}
	used = round1(used)
	resetInt := int64(reset)
	switch window {
	case "5h":
		data.UsedPercent5H = &used
		if resetOK {
			data.ResetsAt5H = &resetInt
		}
	case "weekly":
		data.UsedPercentWeekly = &used
		if resetOK {
			data.ResetsAtWeekly = &resetInt
		}
	}
}

func formatRPCError(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	return "codex RPC error: " + strconv.Quote(redactMessage(string(raw)))
}
