package main

import (
	"context"
	"errors"
	"fmt"

	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// protectedFolder is a location macOS privacy protection (TCC) guards with a
// per-app prompt ("would like to access files in your X folder", "...your
// photo library", "...Apple Music, your music and video activity, and your
// media library", "...data from other apps"). settingName is the toggle's
// label under System Settings > Privacy & Security > Files & Folders, or ""
// when only Full Disk Access covers it.
type protectedFolder struct {
	path, settingName string
}

// homeDataVaults are the rest of the TCC-guarded locations under $HOME: media
// libraries, other apps' data, and the Apple app stores behind the Contacts/
// Calendars/Reminders/Mail/Messages/Safari prompts. QuotaPeek needs none.
var homeDataVaults = []string{
	"Pictures", "Music", "Movies", ".Trash",
	"Library/CloudStorage",
	"Library/Photos",
	"Library/Containers",
	"Library/Group Containers",
	"Library/Daemon Containers",
	"Library/Accounts",
	"Library/Application Support/AddressBook",
	"Library/Application Support/CallHistoryDB",
	"Library/Application Support/CallHistoryTransactions",
	"Library/Application Support/com.apple.TCC",
	"Library/Application Support/FaceTime",
	"Library/Application Support/Knowledge",
	"Library/Application Support/MobileSync",
	"Library/Biome",
	"Library/Calendars",
	"Library/Cookies",
	"Library/HomeKit",
	"Library/IdentityServices",
	"Library/Mail",
	"Library/Messages",
	"Library/Metadata/CoreSpotlight",
	"Library/Reminders",
	"Library/Safari",
	"Library/Suggestions",
}

func protectedFolders() []protectedFolder {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	folders := []protectedFolder{
		{filepath.Join(home, "Desktop"), "Desktop Folder"},
		{filepath.Join(home, "Documents"), "Documents Folder"},
		{filepath.Join(home, "Downloads"), "Downloads Folder"},
		{filepath.Join(home, "Library", "Mobile Documents"), "iCloud Drive"},
		{"/Volumes", ""},
	}
	for _, rel := range homeDataVaults {
		folders = append(folders, protectedFolder{filepath.Join(home, filepath.FromSlash(rel)), ""})
	}
	return folders
}

func protectedFolderFor(path string) (protectedFolder, bool) {
	path = filepath.Clean(path)
	for _, f := range protectedFolders() {
		for _, root := range []string{f.path, realPath(f.path)} {
			if path == root || strings.HasPrefix(path, root+string(os.PathSeparator)) {
				return f, true
			}
		}
	}
	return protectedFolder{}, false
}

// accessError explains a required file QuotaPeek can't read, with the fix,
// so it lands in the app's Account Health tab instead of a bare EPERM.
func accessError(path, purpose string, err error) error {
	if !errors.Is(err, fs.ErrPermission) {
		return err
	}
	if !errors.Is(err, syscall.EPERM) {
		return fmt.Errorf("permission denied reading %s (%s) - make sure it's owned and readable by your user (ls -l %q)", path, purpose, path)
	}
	fix := "turn on quotapeekd under System Settings > Privacy & Security > Full Disk Access (add it with + from ~/Library/Application Support/QuotaPeek/bin/quotapeekd if it isn't listed)"
	if f, ok := protectedFolderFor(path); ok && f.settingName != "" {
		fix = fmt.Sprintf("turn on %q for quotapeekd under System Settings > Privacy & Security > Files & Folders (or grant it Full Disk Access)", f.settingName)
	}
	return fmt.Errorf("macOS is blocking QuotaPeek from reading %s (%s) - %s, then restart QuotaPeek; or move it out of that protected folder", path, purpose, fix)
}

// checkReadableDir reports a required directory macOS privacy protection is
// blocking. A missing directory is left to the collectors to report.
func checkReadableDir(path, purpose string) error {
	f, err := os.Open(path)
	if err == nil {
		_, err = f.Readdirnames(1)
		f.Close()
	}
	if errors.Is(err, fs.ErrPermission) {
		return accessError(path, purpose, err)
	}
	return nil
}

const sandboxExec = "/usr/bin/sandbox-exec"

// providerCommand runs a provider CLI (claude/codex/agy) with the privacy-
// protected folders walled off. Those CLIs load user-level config on start
// that can point anywhere - e.g. a local plugin marketplace in ~/Documents -
// and macOS attributes their file access to quotapeekd, so an unrelated read
// would otherwise pop a "quotapeekd would like to access your Documents
// folder" prompt. The sandbox denial happens before TCC is consulted, so no
// prompt appears; the account's own config dir and the CLI's install dir stay
// reachable because the refresh genuinely needs them.
//
// The CLI also runs from an empty working directory: launchd starts the
// daemon in /, and `agy -p`/`claude -p` treat their cwd as a workspace to
// index, which walked into ~/Pictures and ~/Music and raised photo library
// and media library prompts.
func providerCommand(ctx context.Context, bin string, args ...string) *exec.Cmd {
	var cmd *exec.Cmd
	if _, err := os.Stat(sandboxExec); err != nil {
		cmd = exec.CommandContext(ctx, bin, args...)
	} else {
		var allow []string
		if resolved, err := exec.LookPath(bin); err == nil {
			allow = append(allow, filepath.Dir(realPath(resolved)))
		}
		if pair, ok := ctx.Value(configEnvKey{}).([2]string); ok && pair[1] != "" {
			allow = append(allow, realPath(pair[1]))
		}
		cmd = exec.CommandContext(ctx, sandboxExec, append([]string{"-p", sandboxProfile(allow), bin}, args...)...)
	}
	cmd.Dir = providerWorkDir()
	return cmd
}

// providerEnv is the account-scoped environment for a providerCommand. agy
// takes its workspace from $PWD rather than the real cwd, and an explicit Env
// keeps the daemon's own PWD (/), so point PWD at the empty workdir too;
// exec keeps the last of duplicate keys.
func providerEnv(ctx context.Context, cmd *exec.Cmd) []string {
	return append(collectorEnv(ctx), "PWD="+cmd.Dir)
}

// providerWorkDir is an empty directory QuotaPeek owns, so a CLI that scans
// its workspace on start finds nothing to read.
func providerWorkDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		dir := filepath.Join(home, "Library", "Application Support", "QuotaPeek", "cli-workdir")
		if os.MkdirAll(dir, 0o700) == nil {
			return dir
		}
	}
	return os.TempDir()
}

// Seatbelt matches resolved paths, and the last matching rule wins, so the
// allow rules must come after the denies.
func sandboxProfile(allow []string) string {
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n")
	for _, f := range protectedFolders() {
		fmt.Fprintf(&b, "(deny file-read* file-write* (subpath %s))\n", sbplString(realPath(f.path)))
	}
	for _, p := range allow {
		if _, ok := protectedFolderFor(p); ok {
			fmt.Fprintf(&b, "(allow file-read* file-write* (subpath %s))\n", sbplString(p))
		}
	}
	return b.String()
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return filepath.Clean(p)
}

func sbplString(s string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
}
