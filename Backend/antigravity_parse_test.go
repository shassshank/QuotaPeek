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

func TestClassifyQuotaFamily(t *testing.T) {
	cases := []struct {
		bucket quotaBucket
		want   string
	}{
		{bucket: quotaBucket{id: "gemini-weekly", groupName: "Gemini Models"}, want: "gemini"},
		{bucket: quotaBucket{id: "gemini-5h", groupName: "Gemini Models"}, want: "gemini"},
		{bucket: quotaBucket{id: "3p-weekly", groupName: "Claude and GPT models"}, want: "claude_gpt"},
		{bucket: quotaBucket{id: "claude-weekly", displayName: "Claude 3.5 Sonnet"}, want: "claude"},
		{bucket: quotaBucket{id: "gpt-weekly", displayName: "GPT-4o"}, want: "gpt"},
		{bucket: quotaBucket{id: "generic-bucket"}, want: "default"},
	}
	for _, tc := range cases {
		if got := classifyQuotaFamily(tc.bucket); got != tc.want {
			t.Fatalf("classifyQuotaFamily(%+v) = %q, want %q", tc.bucket, got, tc.want)
		}
	}
}

func TestParseAntigravityQuotaLegacy(t *testing.T) {
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

func TestParseAntigravityQuotaRealStructure(t *testing.T) {
	// Mirrors the live retrieveUserQuotaSummary payload from Antigravity.
	raw := []byte(`{
		"groups": [
			{
				"displayName": "Gemini Models",
				"description": "Models within this group: Gemini Flash, Gemini Pro",
				"buckets": [
					{
						"bucketId": "gemini-weekly",
						"displayName": "Weekly Limit Remaining",
						"window": "weekly",
						"resetTime": "2026-09-10T21:42:46Z",
						"remainingFraction": 0.916
					},
					{
						"bucketId": "gemini-5h",
						"displayName": "Five Hour Limit Remaining",
						"window": "5h",
						"resetTime": "2026-09-08T10:43:40Z",
						"remainingFraction": 0.824
					}
				]
			},
			{
				"displayName": "Claude and GPT models",
				"description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
				"buckets": [
					{
						"bucketId": "3p-weekly",
						"displayName": "Weekly Limit Remaining",
						"window": "weekly",
						"resetTime": "2026-09-14T23:34:49Z",
						"remainingFraction": 0.940
					},
					{
						"bucketId": "3p-5h",
						"displayName": "Five Hour Limit Remaining",
						"window": "5h",
						"resetTime": "2026-09-08T13:26:56Z",
						"remainingFraction": 1.0
					}
				]
			}
		]
	}`)

	data, ok := ParseAntigravityQuota(raw)
	if !ok {
		t.Fatal("ParseAntigravityQuota returned no data")
	}

	// 5h and Weekly must belong to the primary Gemini model family (not collapsed with 3p)
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 17.6 {
		t.Fatalf("UsedPercent5H = %v, want 17.6", data.UsedPercent5H)
	}
	if data.ResetsAt5H == nil || *data.ResetsAt5H != 1788864220 {
		t.Fatalf("ResetsAt5H = %v, want 1788864220", data.ResetsAt5H)
	}
	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 8.4 {
		t.Fatalf("UsedPercentWeekly = %v, want 8.4", data.UsedPercentWeekly)
	}
	if data.ResetsAtWeekly == nil || *data.ResetsAtWeekly != 1789076566 {
		t.Fatalf("ResetsAtWeekly = %v, want 1789076566", data.ResetsAtWeekly)
	}

	// Claude and GPT models group (3p) provides 5h and weekly third-party quota
	if data.UsedPercentWeeklyThirdParty == nil || *data.UsedPercentWeeklyThirdParty != 6.0 {
		t.Fatalf("UsedPercentWeeklyThirdParty = %v, want 6.0", data.UsedPercentWeeklyThirdParty)
	}
	if data.ResetsAtWeeklyThirdParty == nil || *data.ResetsAtWeeklyThirdParty != 1789428889 {
		t.Fatalf("ResetsAtWeeklyThirdParty = %v, want 1789428889", data.ResetsAtWeeklyThirdParty)
	}
	if data.UsedPercent5HThirdParty == nil || *data.UsedPercent5HThirdParty != 0.0 {
		t.Fatalf("UsedPercent5HThirdParty = %v, want 0.0", data.UsedPercent5HThirdParty)
	}
	if data.ResetsAt5HThirdParty == nil || *data.ResetsAt5HThirdParty != 1788874016 {
		t.Fatalf("ResetsAt5HThirdParty = %v, want 1788874016", data.ResetsAt5HThirdParty)
	}
}

func TestParseAntigravityQuotaDistinctClaudeAndGPT(t *testing.T) {
	raw := []byte(`{
		"groups": [
			{
				"displayName": "Gemini Models",
				"buckets": [
					{"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.70, "resetTime": "2026-09-10T20:00:00Z"},
					{"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.60, "resetTime": "2026-09-08T10:00:00Z"}
				]
			},
			{
				"displayName": "Claude Models",
				"buckets": [
					{"bucketId": "claude-weekly", "window": "weekly", "remainingFraction": 0.80, "resetTime": "2026-09-14T20:00:00Z"},
					{"bucketId": "claude-5h", "window": "5h", "remainingFraction": 0.85, "resetTime": "2026-09-08T12:00:00Z"}
				]
			},
			{
				"displayName": "GPT Models",
				"buckets": [
					{"bucketId": "gpt-weekly", "window": "weekly", "remainingFraction": 0.50, "resetTime": "2026-09-15T20:00:00Z"}
				]
			}
		]
	}`)

	data, ok := ParseAntigravityQuota(raw)
	if !ok {
		t.Fatal("ParseAntigravityQuota returned no data")
	}

	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 30.0 {
		t.Fatalf("UsedPercentWeekly = %v, want 30.0", data.UsedPercentWeekly)
	}
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 40.0 {
		t.Fatalf("UsedPercent5H = %v, want 40.0", data.UsedPercent5H)
	}
	if data.UsedPercentWeeklyThirdParty == nil || *data.UsedPercentWeeklyThirdParty != 50.0 {
		t.Fatalf("UsedPercentWeeklyThirdParty = %v, want 50.0", data.UsedPercentWeeklyThirdParty)
	}
	if data.UsedPercent5HThirdParty == nil || *data.UsedPercent5HThirdParty != 15.0 {
		t.Fatalf("UsedPercent5HThirdParty = %v, want 15.0", data.UsedPercent5HThirdParty)
	}
}

func TestParseAntigravityIngestDistinctModels(t *testing.T) {
	raw := []byte(`{
		"quota": {
			"gemini-weekly": {"remaining_fraction": 0.90, "reset_in_seconds": 7200},
			"gemini-5h": {"remaining_fraction": 0.75, "reset_in_seconds": 1800},
			"claude-weekly": {"remaining_fraction": 0.85, "reset_in_seconds": 14400},
			"gpt-weekly": {"remaining_fraction": 0.80, "reset_in_seconds": 14400},
			"3p-5h": {"remaining_fraction": 0.70, "reset_in_seconds": 3600}
		}
	}`)
	data, ok, err := parseAntigravityIngest(raw)
	if err != nil || !ok {
		t.Fatalf("parseAntigravityIngest failed: ok=%v, err=%v", ok, err)
	}
	if data.UsedPercentWeekly == nil || *data.UsedPercentWeekly != 10.0 {
		t.Fatalf("UsedPercentWeekly = %v, want 10.0", data.UsedPercentWeekly)
	}
	if data.UsedPercent5H == nil || *data.UsedPercent5H != 25.0 {
		t.Fatalf("UsedPercent5H = %v, want 25.0", data.UsedPercent5H)
	}
	if data.UsedPercentWeeklyThirdParty == nil || *data.UsedPercentWeeklyThirdParty != 20.0 {
		t.Fatalf("UsedPercentWeeklyThirdParty = %v, want 20.0", data.UsedPercentWeeklyThirdParty)
	}
	if data.UsedPercent5HThirdParty == nil || *data.UsedPercent5HThirdParty != 30.0 {
		t.Fatalf("UsedPercent5HThirdParty = %v, want 30.0", data.UsedPercent5HThirdParty)
	}
}
