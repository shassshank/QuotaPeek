package main

import (
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"
)

var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(access_token|refresh_token|id_token|api[_-]?key|client_secret|authorization)"?\s*[:=]\s*"?[^",}\s]+`),
	regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]+`),
	regexp.MustCompile(`ya29\.[A-Za-z0-9._-]+`),
	regexp.MustCompile(`1//[A-Za-z0-9._~+/-]+`),
	regexp.MustCompile(`eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`),
	regexp.MustCompile(`sk-[A-Za-z0-9._-]+`),
}

func redactMessage(s string) string {
	s = strings.TrimSpace(s)
	for _, re := range secretPatterns {
		s = re.ReplaceAllStringFunc(s, func(match string) string {
			if strings.Contains(strings.ToLower(match), "bearer ") {
				return "Bearer <redacted>"
			}
			parts := regexp.MustCompile(`[:=]`).Split(match, 2)
			if len(parts) == 2 {
				return parts[0] + ":<redacted>"
			}
			return "<redacted>"
		})
	}
	if len(s) > 200 {
		end := 200
		for end > 0 && !utf8.RuneStart(s[end]) {
			end--
		}
		s = s[:end]
	}
	return s
}

// apiErrorMessage pulls just the human-readable message out of a JSON error
// body (Google's {"error":{"message":...}} and OpenAI's {"error":{"message":...}}
// both match this shape) so callers don't have to surface the raw JSON blob to
// users. Falls back to the redacted raw body when the shape doesn't match.
func apiErrorMessage(body []byte) string {
	var parsed struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &parsed); err == nil && parsed.Error.Message != "" {
		return redactMessage(parsed.Error.Message)
	}
	return redactMessage(string(body))
}
