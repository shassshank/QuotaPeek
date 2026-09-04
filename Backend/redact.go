package main

import (
	"regexp"
	"strings"
)

var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(access_token|refresh_token|id_token|api[_-]?key|client_secret|authorization)"?\s*[:=]\s*"?[^",}\s]+`),
	regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]+`),
	regexp.MustCompile(`ya29\.[A-Za-z0-9._-]+`),
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
		s = s[:200]
	}
	return s
}
