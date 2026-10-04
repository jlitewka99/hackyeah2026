"""Exercise the launcher with a fake Docker CLI; never start real containers."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FAKE_DOCKER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
state = Path(os.environ["FAKE_STATE"])
record = {"args": args, "has_bootstrap_password": bool(os.environ.get("AI_CONTROL_ORGANIZER_PASSWORD"))}
if "exec" in args and "AiControl.Release.bootstrap_organizer()" in args:
    record["email"] = os.environ.get("AI_CONTROL_ORGANIZER_EMAIL")
    record["password"] = os.environ.get("AI_CONTROL_ORGANIZER_PASSWORD")
with state.with_suffix(".jsonl").open("a") as output:
    output.write(json.dumps(record) + "\n")

if args == ["compose", "version"]:
    print("Docker Compose version v2.39.0")
elif "up" in args and os.environ.get("FAIL_UP"):
    sys.exit(1)
elif "curl" in args and os.environ.get("FAIL_READY"):
    sys.exit(22)
elif any("organizer_exists?()" in arg for arg in args):
    print("LOCAL_ORGANIZER_EXISTS" if state.exists() else "LOCAL_ORGANIZER_MISSING")
elif "AiControl.Release.bootstrap_organizer()" in args:
    state.touch()
'''


class LocalLauncherTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "docker").mkdir()
        self.script = self.root / "docker/local"
        shutil.copy2(ROOT / "docker/local", self.script)
        (self.root / "bin").mkdir()
        fake = self.root / "bin/docker"
        fake.write_text(FAKE_DOCKER)
        fake.chmod(0o755)
        self.environment = dict(os.environ)
        for name in ("AI_CONTROL_ORGANIZER_EMAIL", "AI_CONTROL_ORGANIZER_PASSWORD"):
            self.environment.pop(name, None)
        self.environment.update(
            PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
            FAKE_STATE=str(self.root / "organizer"),
            DEEPSEEK_API_KEY="synthetic-deepseek-key",
        )

    def run_launcher(self, command, **environment):
        return subprocess.run(
            [str(self.script), command],
            env={**self.environment, **environment},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def records(self):
        return [
            json.loads(line)
            for line in (self.root / "organizer.jsonl").read_text().splitlines()
        ]

    def test_first_start_generates_keys_and_passes_bootstrap_credentials_only_as_environment(self):
        password = "synthetic-password-'$literal"
        result = self.run_launcher(
            "up",
            AI_CONTROL_ORGANIZER_EMAIL="organizer@example.test",
            AI_CONTROL_ORGANIZER_PASSWORD=password,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        secrets = (self.root / ".env.local").read_text()
        self.assertNotIn(password, secrets + result.stdout + result.stderr)
        self.assertNotIn("organizer@example.test", secrets)
        self.assertNotIn("synthetic-deepseek-key", secrets + result.stdout + result.stderr)
        self.assertEqual((self.root / ".env.local").stat().st_mode & 0o777, 0o600)
        values = dict(line.split("=", 1) for line in secrets.splitlines())
        self.assertGreaterEqual(len(base64.b64decode(values["SECRET_KEY_BASE"])), 64)
        for name in ("AUDIT_FINGERPRINT_KEY", "APPROVAL_ENCRYPTION_KEY"):
            self.assertEqual(len(base64.b64decode(values[name])), 32)
        bootstrap = [row for row in self.records() if "password" in row]
        self.assertEqual(len(bootstrap), 1)
        self.assertEqual(bootstrap[0]["password"], password)
        self.assertNotIn(password, " ".join(bootstrap[0]["args"]))
        self.assertFalse(any(row["has_bootstrap_password"] for row in self.records() if "password" not in row))

    def test_restart_preserves_keys_and_existing_organizer_without_credentials(self):
        first = self.run_launcher(
            "up",
            AI_CONTROL_ORGANIZER_EMAIL="organizer@example.test",
            AI_CONTROL_ORGANIZER_PASSWORD="synthetic-password",
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        secrets = (self.root / ".env.local").read_bytes()
        second = self.run_launcher("up")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.root / ".env.local").read_bytes(), secrets)
        self.assertEqual(len([row for row in self.records() if "password" in row]), 1)
        self.assertIn("Local environment ready", second.stdout)

    def test_noninteractive_first_start_requires_explicit_credentials(self):
        result = self.run_launcher("up")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set AI_CONTROL_ORGANIZER_EMAIL", result.stderr)
        self.assertNotIn("Local environment ready", result.stdout)

    def test_missing_deepseek_key_stops_before_building_or_starting_services(self):
        result = self.run_launcher("up", DEEPSEEK_API_KEY="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set DEEPSEEK_API_KEY", result.stderr)
        self.assertFalse(any("up" in row["args"] for row in self.records()))
        self.assertNotIn("Local environment ready", result.stdout)

    def test_startup_or_readiness_failure_never_reports_success(self):
        for environment in ({"FAIL_UP": "1"}, {"FAIL_READY": "1"}):
            with self.subTest(environment=environment):
                result = self.run_launcher("up", **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Local environment ready", result.stdout)

    def test_down_preserves_keys_and_does_not_remove_volumes(self):
        (self.root / ".env.local").write_text("synthetic-existing-configuration\n")
        result = self.run_launcher("down")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / ".env.local").exists())
        down = [row for row in self.records() if "down" in row["args"]]
        self.assertEqual(len(down), 1)
        self.assertNotIn("--volumes", down[0]["args"])

    def test_status_and_logs_dispatch_without_bootstrapping(self):
        (self.root / ".env.local").write_text("synthetic-existing-configuration\n")
        for command, expected in (("status", "ps"), ("logs", "logs")):
            result = self.run_launcher(command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, self.records()[-1]["args"])
        self.assertFalse(any("password" in row for row in self.records()))

    def test_unknown_command_does_not_generate_configuration(self):
        result = self.run_launcher("reset")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / ".env.local").exists())


if __name__ == "__main__":
    unittest.main()
