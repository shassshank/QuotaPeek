package main

import (
	"encoding/json"
	"testing"
)

func TestParseCodexRateLimitsUsesWindowDuration(t *testing.T) {
	raw := json.RawMessage(`{"rateLimits":{
		"primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":111},
		"secondary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":222},
		"planType":"plus"
	}}`)
	data, err := ParseCodexRateLimits(raw)
	if err != nil {
		t.Fatal(err)
	}
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 22 {
		t.Fatalf("5h usage = %v, want 22", data.UsedPercent5H)
	}
	if data.ResetsAt5H == nil || *data.ResetsAt5H != 222 {
		t.Fatalf("5h reset = %v, want 222", data.ResetsAt5H)
	}
	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 11 {
		t.Fatalf("weekly usage = %v, want 11", data.UsedPercentWeekly)
	}
}

func TestParseCodexRateLimitsPositionFallback(t *testing.T) {
	raw := json.RawMessage(`{"rateLimits":{
		"primary":{"usedPercent":33,"resetsAt":333},
		"secondary":{"usedPercent":44,"resetsAt":444}
	}}`)
	data, err := ParseCodexRateLimits(raw)
	if err != nil {
		t.Fatal(err)
	}
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 33 {
		t.Fatalf("5h usage = %v, want 33", data.UsedPercent5H)
	}
	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 44 {
		t.Fatalf("weekly usage = %v, want 44", data.UsedPercentWeekly)
	}
}
