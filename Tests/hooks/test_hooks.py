"""End-to-end tests for the statusline hooks: run the real scripts against a
temporary support dir with a bound socket and a snapshot file.

Run: python3 -m unittest discover -s Tests/hooks
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Scripts")


def run_hook(name, payload, support_dir):
    env = dict(os.environ, QUOTAPEEK_SUPPORT_DIR=support_dir)
    started = time.monotonic()
    out = subprocess.run([sys.executable, os.path.join(SCRIPTS, name)], input=json.dumps(payload),
                         capture_output=True, text=True, env=env, timeout=10)
    return out, time.monotonic() - started


class HookTests(unittest.TestCase):
    def setUp(self):
        # Short path: sun_path is limited to 104 bytes.
        self.dir = tempfile.mkdtemp(prefix="qp", dir="/tmp")
        self.sock_path = os.path.join(self.dir, "qp.sock")

    def tearDown(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def bind(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        sock.bind(self.sock_path)
        sock.settimeout(2)
        self.addCleanup(sock.close)
        return sock

    def write_snapshot(self, pid):
        snapshot = {"v": 1, "pid": pid, "statusline_show_other_agents": True, "accounts": [
            {"provider": "claude", "label": "P", "state": "fresh", "data": {"used_percent_5h": 99}},
            {"provider": "codex", "label": "P", "state": "fresh",
             "data": {"used_percent_5h": 12, "resets_at_5h": time.time() + 3 * 3600 + 120}},
            {"provider": "antigravity", "label": "P", "state": "error", "data": {"used_percent_5h": 50}},
        ]}
        with open(os.path.join(self.dir, "snapshot.json"), "w") as f:
            json.dump(snapshot, f)

    def test_claude_hook_sends_reading_and_shows_other_agents(self):
        sock = self.bind()
        self.write_snapshot(os.getpid())
        payload = {"model": {"display_name": "Opus"},
                   "rate_limits": {"five_hour": {"used_percentage": 30, "resets_at": 1}}}
        out, _ = run_hook("claude-statusline-hook.py", payload, self.dir)
        self.assertEqual(out.returncode, 0, out.stderr)
        line = out.stdout.strip()
        self.assertTrue(line.startswith("Opus | 30% "), line)
        self.assertRegex(line, r"\| Codex 12% ▓░{9} 3h[12]m$")
        self.assertNotIn("Claude 99%", line)        # own provider excluded
        self.assertNotIn("Antigravity", line)       # error state skipped

        msg = json.loads(sock.recv(65536))
        self.assertEqual(msg["v"], 1)
        self.assertEqual(msg["provider"], "claude")
        self.assertEqual(msg["rate_limits"], payload["rate_limits"])
        self.assertIn("config_dir", msg)
        self.assertAlmostEqual(msg["observed_at_ms"] / 1000, time.time(), delta=10)

    def test_antigravity_hook_sends_quota(self):
        sock = self.bind()
        payload = {"model": "Gemini", "quota": {"Gemini 5h": {"remaining_fraction": 0.5, "reset_in_seconds": 60}}}
        out, _ = run_hook("antigravity-statusline-hook.py", payload, self.dir)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(out.stdout.startswith("Gemini | 50% "), out.stdout)
        msg = json.loads(sock.recv(65536))
        self.assertEqual((msg["provider"], msg["quota"]), ("antigravity", payload["quota"]))

    def test_app_not_running_is_silent_and_fast(self):
        payload = {"model": {"display_name": "Opus"},
                   "rate_limits": {"five_hour": {"used_percentage": 30, "resets_at": 1}}}
        out, elapsed = run_hook("claude-statusline-hook.py", payload, self.dir)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stderr, "")
        self.assertTrue(out.stdout.startswith("Opus | 30%"))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "hook-errors.log")))
        self.assertLess(elapsed, 1.0)

    def test_snapshot_from_dead_app_is_ignored(self):
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        self.write_snapshot(dead.pid)
        out, _ = run_hook("claude-statusline-hook.py", {"model": {"display_name": "Opus"}}, self.dir)
        self.assertEqual(out.stdout.strip(), "Opus")

    def test_garbage_stdin_still_prints_a_statusline(self):
        env = dict(os.environ, QUOTAPEEK_SUPPORT_DIR=self.dir)
        for name, fallback in (("claude-statusline-hook.py", "Claude Code"), ("antigravity-statusline-hook.py", "Antigravity")):
            out = subprocess.run([sys.executable, os.path.join(SCRIPTS, name)], input="not json",
                                 capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual((out.returncode, out.stdout.strip()), (0, fallback))


if __name__ == "__main__":
    unittest.main()
