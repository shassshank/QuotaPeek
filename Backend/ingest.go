package main

import (
	"encoding/json"
	"errors"
	"math"
	"sort"
	"strconv"
	"strings"
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
			data.UsedPercent5H = floatPtr(claudeUsedPercentage(w))
			data.ResetsAt5H = intPtr(int64FromAny(w["resets_at"]))
		}
		if w, ok := rl["seven_day"].(map[string]any); ok {
			data.UsedPercentWeekly = floatPtr(claudeUsedPercentage(w))
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
		keys := make([]string, 0, len(quota))
		for key := range quota {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			value := quota[key]
			entry, ok := value.(map[string]any)
			if !ok {
				continue
			}
			remaining, ok := numberFromAny(entry["remaining_fraction"])
			if !ok || remaining < 0 || remaining > 1 {
				continue
			}
			used := round1((1 - remaining) * 100)
			reset := parseReset(entry["reset_time"])
			if seconds, ok := numberFromAny(entry["reset_in_seconds"]); ok {
				at := time.Now().Unix() + int64(seconds)
				reset = &at
			}
			label := strings.ToLower(key)
			switch classifyQuotaLabel(label) {
			case "weekly":
				hasClaude := strings.Contains(label, "claude")
				hasGPT := strings.Contains(label, "gpt")
				has3P := strings.Contains(label, "3p")
				if (hasClaude && hasGPT) || has3P {
					if data.UsedPercentWeeklyClaude == nil || used > *data.UsedPercentWeeklyClaude {
						data.UsedPercentWeeklyClaude = &used
						data.ResetsAtWeeklyClaude = reset
					}
					if data.UsedPercentWeeklyGPT == nil || used > *data.UsedPercentWeeklyGPT {
						data.UsedPercentWeeklyGPT = &used
						data.ResetsAtWeeklyGPT = reset
					}
				} else if hasClaude {
					if data.UsedPercentWeeklyClaude == nil || used > *data.UsedPercentWeeklyClaude {
						data.UsedPercentWeeklyClaude = &used
						data.ResetsAtWeeklyClaude = reset
					}
				} else if hasGPT {
					if data.UsedPercentWeeklyGPT == nil || used > *data.UsedPercentWeeklyGPT {
						data.UsedPercentWeeklyGPT = &used
						data.ResetsAtWeeklyGPT = reset
					}
				} else {
					if data.UsedPercentWeekly == nil || used > *data.UsedPercentWeekly {
						data.UsedPercentWeekly = &used
						data.ResetsAtWeekly = reset
					}
				}
			case "5h":
				if data.UsedPercent5H == nil || used > *data.UsedPercent5H {
					data.UsedPercent5H = &used
					data.ResetsAt5H = reset
				}
			}
		}
	}
	if data.UsedPercentWeekly == nil {
		if data.UsedPercentWeeklyClaude != nil {
			data.UsedPercentWeekly = data.UsedPercentWeeklyClaude
			data.ResetsAtWeekly = data.ResetsAtWeeklyClaude
		} else if data.UsedPercentWeeklyGPT != nil {
			data.UsedPercentWeekly = data.UsedPercentWeeklyGPT
			data.ResetsAtWeekly = data.ResetsAtWeeklyGPT
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
		return x, !math.IsNaN(x) && !math.IsInf(x, 0)
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case json.Number:
		n, err := x.Float64()
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
	case string:
		n, err := strconv.ParseFloat(x, 64)
		return n, err == nil && !math.IsNaN(n) && !math.IsInf(n, 0)
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
	if math.Abs(v) > math.MaxFloat64/10 {
		return v
	}
	return math.Round(v*10) / 10
}

func claudeUsedPercentage(window map[string]any) (float64, bool) {
	if value, ok := numberFromAny(window["used_percentage"]); ok {
		return value, true
	}
	return numberFromAny(window["used_percent"])
}
