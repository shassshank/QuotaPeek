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

// The photo library, media library and other-apps-data prompts come from
// these, so they must stay in the sandbox's deny list.
func TestSandboxProfileDeniesPersonalDataVaults(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	p := sandboxProfile(nil)
	for _, rel := range []string{"Pictures", "Music", "Movies", "Library/Photos", "Library/Containers", "Library/Group Containers", "Library/Calendars", "Library/Application Support/AddressBook", "Library/Mail"} {
		want := `(deny file-read* file-write* (subpath "` + realPath(filepath.Join(home, rel)) + `"))`
		if !strings.Contains(p, want) {
			t.Errorf("%s not denied:\n%s", rel, p)
		}
	}
}

func TestProviderCommandRunsFromEmptyPrivateDir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cmd := providerCommand(context.Background(), "/bin/pwd")
	want := filepath.Join(home, "Library", "Application Support", "QuotaPeek", "cli-workdir")
	if cmd.Dir != want {
		t.Fatalf("Dir = %q, want %q (never launchd's /)", cmd.Dir, want)
	}
	if entries, err := os.ReadDir(want); err != nil || len(entries) != 0 {
		t.Fatalf("workdir should exist and be empty: %v %v", entries, err)
	}
	if info, _ := os.Stat(want); info.Mode().Perm() != 0o700 {
		t.Fatalf("workdir mode = %v, want 0700", info.Mode().Perm())
	}
	// agy reads its workspace from $PWD, which must not leak the daemon's own.
	t.Setenv("PWD", "/")
	sh := providerCommand(context.Background(), "/bin/sh", "-c", `printf %s "$PWD"`)
	sh.Env = providerEnv(context.Background(), sh)
	if out, err := sh.Output(); err != nil || string(out) != want {
		t.Fatalf("child PWD = %q (%v), want %q", out, err, want)
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
	photos := filepath.Join(home, "Pictures", "Photos Library.photoslibrary")
	if err := os.MkdirAll(photos, 0o700); err != nil {
		t.Fatal(err)
	}
	out, err = providerCommand(ctx, "/bin/ls", photos).CombinedOutput()
	if err == nil || !strings.Contains(string(out), "Operation not permitted") {
		t.Fatalf("photo library should be denied, got err=%v out=%s", err, out)
	}
}
