#!/usr/bin/env python3
"""Exercise the staged-content guard with synthetic data in disposable repos."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).with_name("pre-commit").resolve()
PADDING = "harmless text\n" * 40000
TOKEN = "sk-" + "A" * 40


class PreCommitTests(unittest.TestCase):
    def run_hook(self, staged, unstaged=None):
        with tempfile.TemporaryDirectory(prefix="meterusage-hook-") as directory:
            root = Path(directory)
            env = os.environ.copy()
            for key in list(env):
                if key.startswith("GIT_"):
                    del env[key]
            env["GIT_CONFIG_NOSYSTEM"] = "1"
            env["GIT_CONFIG_GLOBAL"] = os.devnull
            env["HOME"] = directory
            subprocess.run(["git", "init", "-q", directory], env=env, check=True)
            sample = root / "sample.txt"
            sample.write_text(staged)
            subprocess.run(["git", "add", "sample.txt"], cwd=root, env=env, check=True)
            if unstaged is not None:
                sample.write_text(unstaged)
            return subprocess.run(
                ["bash", str(HOOK)], cwd=root, env=env,
                capture_output=True, text=True, timeout=10,
            )

    def test_token_at_each_position_in_large_diff_is_blocked(self):
        for before, after in [("", PADDING), (PADDING, PADDING), (PADDING, "")]:
            with self.subTest(position=len(before)):
                result = self.run_hook(before + TOKEN + "\n" + after)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("BLOCKED: OpenAI key", result.stderr)

    def test_personal_paths_in_large_diff_are_blocked(self):
        # Many extracted matches also exercise the final path-filter consumer.
        path = "/Users/" + "private-fixture/\n"
        result = self.run_hook(path * 40000 + PADDING)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("BLOCKED: absolute /Users/", result.stderr)

    def test_large_clean_diff_and_reserved_fixture_paths_are_allowed(self):
        result = self.run_hook(PADDING + "/Users/testuser/\n/Users/example/\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unstaged_secret_is_not_scanned(self):
        result = self.run_hook("safe\n", TOKEN + "\n" + PADDING)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_small_staged_secret_is_blocked(self):
        result = self.run_hook(TOKEN + "\n")
        self.assertEqual(result.returncode, 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
