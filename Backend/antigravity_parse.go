package main

import (
	"encoding/json"
	"strings"
)

type quotaBucket struct {
	id                string
	displayName       string
	window            string
	remainingFraction float64
	resetTime         any
}

func ParseAntigravityQuota(raw []byte) (UsageData, bool) {
	var root any
	if err := json.Unmarshal(raw, &root); err != nil {
		return UsageData{}, false
	}
	buckets := collectQuotaBuckets(root, "")
	data := UsageData{}
	for _, bucket := range buckets {
		used := round1((1 - bucket.remainingFraction) * 100)
		reset := parseReset(bucket.resetTime)
		switch classifyQuotaLabel(strings.Join([]string{bucket.id, bucket.displayName, bucket.window}, " ")) {
		case "weekly":
			if data.UsedPercentWeekly == nil || used > *data.UsedPercentWeekly {
				data.UsedPercentWeekly = &used
				data.ResetsAtWeekly = reset
			}
		case "5h":
			if data.UsedPercent5H == nil || used > *data.UsedPercent5H {
				data.UsedPercent5H = &used
				data.ResetsAt5H = reset
			}
		}
	}
	return data, !data.empty()
}

func collectQuotaBuckets(v any, inheritedID string) []quotaBucket {
	var buckets []quotaBucket
	switch x := v.(type) {
	case map[string]any:
		if b, ok := quotaBucketFromMap(x, inheritedID); ok {
			buckets = append(buckets, b)
		}
		for k, child := range x {
			buckets = append(buckets, collectQuotaBuckets(child, k)...)
		}
	case []any:
		for _, child := range x {
			buckets = append(buckets, collectQuotaBuckets(child, inheritedID)...)
		}
	}
	return buckets
}

func quotaBucketFromMap(m map[string]any, fallbackID string) (quotaBucket, bool) {
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
