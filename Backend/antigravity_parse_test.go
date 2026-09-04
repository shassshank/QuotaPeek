package main

import "testing"

func TestClassifyQuotaLabel(t *testing.T) {
	cases := map[string]string{
		"gemini-weekly":       "weekly",
		"quota 7d":            "weekly",
		"model 5h":            "5h",
		"5 hour rolling":      "5h",
		"hourly quota bucket": "unknown",
	}
	for label, want := range cases {
		if got := classifyQuotaLabel(label); got != want {
			t.Fatalf("classifyQuotaLabel(%q) = %q, want %q", label, got, want)
		}
	}
}

func TestParseAntigravityQuota(t *testing.T) {
	raw := []byte(`{
		"outer": {
			"hourly": {"remainingFraction": 0.50, "resetTime": "2026-07-06T07:50:32Z"},
			"five": {"id": "rolling-5h", "remaining_fraction": 0.75},
			"week": {"displayName": "Gemini Weekly", "remainingFraction": 0.90}
		}
	}`)
	data, ok := ParseAntigravityQuota(raw)
	if !ok {
		t.Fatal("ParseAntigravityQuota returned no data")
	}
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 25 {
		t.Fatalf("5h usage = %v, want 25", data.UsedPercent5H)
	}
	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 10 {
		t.Fatalf("weekly usage = %v, want 10", data.UsedPercentWeekly)
	}
}
