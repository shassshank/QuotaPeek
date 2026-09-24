package main

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestAccessErrorExplainsFix(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	docs := filepath.Join(home, "Documents", "claude")
	eperm := &fs.PathError{Op: "open", Path: docs, Err: syscall.EPERM}
	if msg := accessError(docs, "claude config", eperm).Error(); !strings.Contains(msg, `"Documents Folder"`) || !strings.Contains(msg, "Files & Folders") {
		t.Fatalf("Documents EPERM should point at the Files & Folders toggle: %s", msg)
	}
	other := filepath.Join(home, ".codex", "auth.json")
	if msg := accessError(other, "Codex login", eperm).Error(); !strings.Contains(msg, "Full Disk Access") {
		t.Fatalf("unmapped EPERM should suggest Full Disk Access: %s", msg)
	}
	eacces := &fs.PathError{Op: "open", Path: other, Err: syscall.EACCES}
	if msg := accessError(other, "Codex login", eacces).Error(); !strings.Contains(msg, "ls -l") {
		t.Fatalf("EACCES should point at file ownership: %s", msg)
	}
	plain := errors.New("boom")
	if accessError(other, "x", plain) != plain {
		t.Fatal("non-permission errors must pass through unchanged")
	}
}

func TestCheckRequiredAccessReportsBlockedConfigDir(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	blocked := filepath.Join(t.TempDir(), "claude-work")
	if err := os.Mkdir(blocked, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(blocked, 0o700)
	missing := filepath.Join(t.TempDir(), "gone")
	cfg := Config{Accounts: []AccountConfig{
		{ID: "acct_blocked", Provider: ProviderClaude, Label: "Work", CredentialLocation: CredentialLocation{Kind: "config_dir", ConfigDir: &blocked}},
		{ID: "acct_missing", Provider: ProviderCodex, Label: "Gone", CredentialLocation: CredentialLocation{Kind: "config_dir", ConfigDir: &missing}},
	}}
	issues := checkRequiredAccess(cfg)
	if len(issues) != 1 || issues[0].provider != "acct_blocked" || !strings.Contains(issues[0].message, blocked) {
		t.Fatalf("want one issue for the unreadable dir, got %+v", issues)
	}
}

func TestSandboxProfileAllowsOnlyNeededProtectedPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	docs := realPath(filepath.Join(home, "Documents"))
	acct := filepath.Join(docs, "acct")
	p := sandboxProfile([]string{acct, "/opt/homebrew/bin"})
	if !strings.Contains(p, `(deny file-read* file-write* (subpath "`+docs+`"))`) {
		t.Fatalf("Documents not denied:\n%s", p)
	}
	if !strings.Contains(p, `(allow file-read* file-write* (subpath "`+acct+`"))`) {
		t.Fatalf("account dir inside Documents not re-allowed:\n%s", p)
	}
	if strings.Contains(p, "/opt/homebrew") {
		t.Fatalf("unprotected paths need no allow rule:\n%s", p)
	}
	if strings.Index(p, "(deny") > strings.Index(p, "(allow file-read") {
		t.Fatalf("allow rules must follow the denies (last match wins):\n%s", p)
	}
}

// End to end through the real seatbelt: a provider CLI can read its own
// config dir even inside ~/Documents, but nothing else there.
func TestProviderCommandWallsOffProtectedFolders(t *testing.T) {
	if _, err := os.Stat(sandboxExec); err != nil {
		t.Skip("sandbox-exec unavailable")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	acct := filepath.Join(home, "Documents", "acct")
	if err := os.MkdirAll(acct, 0o700); err != nil {
		t.Fatal(err)
	}
	secret := filepath.Join(home, "Documents", "secret.txt")
	own := filepath.Join(acct, "auth.json")
	for _, f := range []string{secret, own} {
		if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	ctx := withConfigDir(context.Background(), "CODEX_HOME", acct)
	if out, err := providerCommand(ctx, "/bin/cat", own).CombinedOutput(); err != nil {
		t.Fatalf("own config dir should stay readable: %v %s", err, out)
	}
	out, err := providerCommand(ctx, "/bin/cat", secret).CombinedOutput()
	if err == nil || !strings.Contains(string(out), "Operation not permitted") {
		t.Fatalf("rest of Documents should be denied, got err=%v out=%s", err, out)
	}
}
