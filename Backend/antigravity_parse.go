package main

import (
	"encoding/json"
	"strings"
)

type quotaBucket struct {
	id                string
	displayName       string
	window            string
	groupName         string
	remainingFraction float64
	resetTime         any
}

func ParseAntigravityQuota(raw []byte) (UsageData, bool) {
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return UsageData{}, false
	}
	buckets := collectQuotaBuckets(root, "", "")
	data := UsageData{}

	var genericWeekly *float64
	var genericWeeklyReset *int64
	var generic5H *float64
	var generic5HReset *int64

	for _, bucket := range buckets {
		used := round1((1 - bucket.remainingFraction) * 100)
		reset := parseReset(bucket.resetTime)
		win := classifyQuotaWindow(bucket)
		fam := classifyQuotaFamily(bucket)

		switch win {
		case "weekly":
			switch fam {
			case "claude":
				data.UsedPercentWeeklyClaude = &used
				data.ResetsAtWeeklyClaude = reset
			case "gpt":
				data.UsedPercentWeeklyGPT = &used
				data.ResetsAtWeeklyGPT = reset
			case "claude_gpt":
				data.UsedPercentWeeklyClaude = &used
				data.ResetsAtWeeklyClaude = reset
				data.UsedPercentWeeklyGPT = &used
				data.ResetsAtWeeklyGPT = reset
			case "gemini":
				data.UsedPercentWeekly = &used
				data.ResetsAtWeekly = reset
			default:
				if genericWeekly == nil || used > *genericWeekly {
					genericWeekly = &used
					genericWeeklyReset = reset
				}
			}
		case "5h":
			switch fam {
			case "gemini":
				data.UsedPercent5H = &used
				data.ResetsAt5H = reset
			default:
				if generic5H == nil || used > *generic5H {
					generic5H = &used
					generic5HReset = reset
				}
			}
		}
	}

	// For Antigravity, UsedPercentWeekly / ResetsAtWeekly represents the primary Gemini
	// weekly quota, aligned with UsedPercent5H / ResetsAt5H (Gemini 5-hour limit).
	// If an explicit Gemini bucket was not present, fall back to generic or 3P buckets.
	if data.UsedPercentWeekly == nil {
		if genericWeekly != nil {
			data.UsedPercentWeekly = genericWeekly
			data.ResetsAtWeekly = genericWeeklyReset
		} else if data.UsedPercentWeeklyClaude != nil {
			data.UsedPercentWeekly = data.UsedPercentWeeklyClaude
			data.ResetsAtWeekly = data.ResetsAtWeeklyClaude
		} else if data.UsedPercentWeeklyGPT != nil {
			data.UsedPercentWeekly = data.UsedPercentWeeklyGPT
			data.ResetsAtWeekly = data.ResetsAtWeeklyGPT
		}
	}
	if data.UsedPercent5H == nil && generic5H != nil {
		data.UsedPercent5H = generic5H
		data.ResetsAt5H = generic5HReset
	}

	return data, !data.empty()
}

func collectQuotaBuckets(v any, inheritedID, inheritedGroup string) []quotaBucket {
	var buckets []quotaBucket
	switch x := v.(type) {
	case map[string]any:
		group := stringValue(first(x, "displayName", "display_name", "name", "groupName", "group_name"))
		if group == "" {
			group = inheritedGroup
		}
		if b, ok := quotaBucketFromMap(x, inheritedID, group); ok {
			buckets = append(buckets, b)
		}
		for k, child := range x {
			childGroup := group
			if childGroup == "" && (k == "groups" || k == "buckets") {
				childGroup = inheritedGroup
			}
			buckets = append(buckets, collectQuotaBuckets(child, k, childGroup)...)
		}
	case []any:
		for _, child := range x {
			buckets = append(buckets, collectQuotaBuckets(child, inheritedID, inheritedGroup)...)
		}
	}
	return buckets
}

func quotaBucketFromMap(m map[string]any, fallbackID, groupName string) (quotaBucket, bool) {
	remaining, ok := numberFromAny(first(m, "remainingFraction", "remaining_fraction"))
	if !ok {
		return quotaBucket{}, false
	}
	id := stringValue(first(m, "bucketId", "bucket_id", "id", "modelId", "model_id"))
	if id == "" {
		id = fallbackID
	}
	if id == "" {
		id = "quota"
	}
	return quotaBucket{
		id:                id,
		displayName:       stringValue(first(m, "displayName", "display_name", "name")),
		window:            stringValue(first(m, "window", "windowName", "window_name", "quotaType", "quota_type")),
		groupName:         groupName,
		remainingFraction: remaining,
		resetTime:         first(m, "resetTime", "reset_time"),
	}, true
}

func first(m map[string]any, keys ...string) any {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			return v
		}
	}
	return nil
}

func classifyQuotaWindow(b quotaBucket) string {
	combined := strings.ToLower(strings.Join([]string{b.window, b.id, b.displayName}, " "))
	if strings.Contains(combined, "week") || strings.Contains(combined, "7d") {
		return "weekly"
	}
	if strings.Contains(combined, "5h") || strings.Contains(combined, "5 hour") {
		return "5h"
	}
	return "unknown"
}

func classifyQuotaFamily(b quotaBucket) string {
	combined := strings.ToLower(strings.Join([]string{b.id, b.displayName, b.groupName}, " "))
	hasClaude := strings.Contains(combined, "claude")
	hasGPT := strings.Contains(combined, "gpt")
	has3P := strings.Contains(combined, "3p")

	if (hasClaude && hasGPT) || has3P {
		return "claude_gpt"
	}
	if hasClaude {
		return "claude"
	}
	if hasGPT {
		return "gpt"
	}
	if strings.Contains(combined, "gemini") {
		return "gemini"
	}
	return "default"
}

func classifyQuotaLabel(label string) string {
	label = strings.ToLower(label)
	if strings.Contains(label, "week") || strings.Contains(label, "7d") {
		return "weekly"
	}
	if strings.Contains(label, "5h") || strings.Contains(label, "5 hour") {
		return "5h"
	}
	return "unknown"
}
