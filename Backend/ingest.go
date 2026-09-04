package main

import (
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"time"
)

func parseClaudeIngest(raw []byte) (UsageData, bool, error) {
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return UsageData{}, false, err
	}
	data := UsageData{}
	if rl, ok := payload["rate_limits"].(map[string]any); ok {
		if w, ok := rl["five_hour"].(map[string]any); ok {
			data.UsedPercent5H = floatPtr(numberFromAny(w["used_percentage"]))
			data.ResetsAt5H = intPtr(int64FromAny(w["resets_at"]))
		}
		if w, ok := rl["seven_day"].(map[string]any); ok {
			data.UsedPercentWeekly = floatPtr(numberFromAny(w["used_percentage"]))
			data.ResetsAtWeekly = intPtr(int64FromAny(w["resets_at"]))
		}
	}
	if ctx, ok := payload["context_window"].(map[string]any); ok {
		data.ContextWindowUsedPercent = floatPtr(numberFromAny(ctx["used_percentage"]))
	}
	if data.empty() {
		return data, false, nil
	}
	return data, true, nil
}

func parseAntigravityIngest(raw []byte) (UsageData, bool, error) {
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return UsageData{}, false, err
	}
	data := UsageData{}
	if quota, ok := payload["quota"].(map[string]any); ok {
		for key, value := range quota {
			entry, ok := value.(map[string]any)
			if !ok {
				continue
			}
			remaining, ok := numberFromAny(entry["remaining_fraction"])
			if !ok {
				continue
			}
			used := round1((1 - remaining) * 100)
			reset := parseReset(entry["reset_time"])
			label := key
			switch classifyQuotaLabel(label) {
			case "weekly":
				data.UsedPercentWeekly = &used
				if reset != nil {
					data.ResetsAtWeekly = reset
				}
			case "5h":
				data.UsedPercent5H = &used
				if reset != nil {
					data.ResetsAt5H = reset
				}
			}
		}
	}
	if ctx, ok := payload["context_window"].(map[string]any); ok {
		data.ContextWindowUsedPercent = floatPtr(numberFromAny(ctx["used_percentage"]))
	}
	if data.empty() {
		return data, false, errors.New("antigravity ingest payload had no parseable usage fields")
	}
	return data, true, nil
}

func parseReset(v any) *int64 {
	switch x := v.(type) {
	case float64:
		i := int64(x)
		return &i
	case string:
		if i, ok := numberFromAny(x); ok {
			out := int64(i)
			return &out
		}
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
			if t, err := time.Parse(layout, x); err == nil {
				out := t.Unix()
				return &out
			}
		}
	}
	return nil
}

func int64FromAny(v any) (int64, bool) {
	n, ok := numberFromAny(v)
	return int64(n), ok
}

func numberFromAny(v any) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		n, err := x.Float64()
		return n, err == nil
	case string:
		n, err := strconv.ParseFloat(x, 64)
		return n, err == nil
	default:
		return 0, false
	}
}

func floatPtr(v float64, ok bool) *float64 {
	if !ok {
		return nil
	}
	return &v
}

func intPtr(v int64, ok bool) *int64 {
	if !ok {
		return nil
	}
	return &v
}

func round1(v float64) float64 {
	return math.Round(v*10) / 10
}
