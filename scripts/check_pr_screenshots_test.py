"""Tests for scripts/check-pr-screenshots.py: python3 scripts/check_pr_screenshots_test.py"""

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check-pr-screenshots.py")
_spec = importlib.util.spec_from_file_location("check_pr_screenshots", SCRIPT)
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

A = "![shot](https://raw.githubusercontent.com/o/r/issue-media/1/a.png)"
B = "![shot](https://raw.githubusercontent.com/o/r/issue-media/1/b.png)"


class Screenshots(unittest.TestCase):
    def assertFound(self, body, before, after):
        self.assertEqual(check.screenshots(body), {"before": before, "after": after})

    def test_headings(self):
        self.assertFound(f"## What\nText.\n\n## Before\n{A}\n\n## After\n{B}\n", 1, 1)

    def test_bold_labels_with_colons(self):
        self.assertFound(f"**Before:**\n\n{A}\n\n**After:**\n\n{B}", 1, 1)

    def test_plain_labels(self):
        self.assertFound(f"Before\n{A}\nAfter\n{B}", 1, 1)

    def test_side_by_side_table(self):
        self.assertFound(f"| Before | After |\n|---|---|\n| {A} | {B} |\n", 1, 1)

    def test_html_images_with_alt_text_and_no_headings(self):
        body = (
            '<img alt="Before: menu clipped" src="https://x/a.png">\n'
            '<img alt="after" src="https://x/b.png">'
        )
        self.assertFound(body, 1, 1)

    def test_markdown_alt_text(self):
        self.assertFound("![before](https://x/a.png) ![after](https://x/b.png)", 1, 1)

    def test_one_image_is_not_enough(self):
        self.assertFound(f"## After\n{B}\n", 0, 1)

    def test_unlabelled_images_do_not_count(self):
        self.assertFound(f"## Screenshots\n{A}\n{B}\n", 0, 0)

    def test_a_new_section_ends_the_label(self):
        self.assertFound(f"## Before\n{A}\n\n## Tests\n{B}\n", 1, 0)

    def test_code_blocks_do_not_count(self):
        body = f"```\n## Before\n{A}\n## After\n{B}\n```\nand `![after](x)`"
        self.assertFound(body, 0, 0)

    def test_several_images_per_side(self):
        self.assertFound(f"## Before\n{A}\n{A}\n## After\n{B}\n{B}\n", 2, 2)


class Main(unittest.TestCase):
    def run_event(self, pr, *flags, action="opened", sender="author"):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"action": action, "sender": {"login": sender}, "pull_request": pr}, f)
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--event", f.name, *flags],
            capture_output=True,
            text=True,
            env={},
        )

    def base(self, **extra):
        pr = {
            "number": 7,
            "body": "",
            "labels": [],
            "state": "open",
            "head": {"ref": "fix/x"},
            "user": {"type": "User", "login": "author"},
            "created_at": "2026-10-24T00:00:00Z",
        }
        pr.update(extra)
        return pr

    def test_missing_screenshots_fail(self):
        result = self.run_event(self.base(body="Fixes a thing."))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing before and after screenshot", result.stdout)

    def test_before_and_after_pass(self):
        result = self.run_event(self.base(body=f"## Before\n{A}\n## After\n{B}"))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_exemptions(self):
        for pr in (
            self.base(labels=[{"name": "no-screenshots"}]),
            self.base(head={"ref": "release/v0.2.134"}),
            self.base(user={"type": "Bot"}),
            self.base(created_at="2026-10-20T00:00:00Z"),
        ):
            self.assertEqual(self.run_event(pr).returncode, 0)


class Enforce(Main):
    def enforce(self, pr, **kw):
        result = self.run_event(pr, "--enforce", "--dry-run", **kw)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_a_new_pull_request_without_screenshots_is_closed(self):
        out = self.enforce(self.base(body="Fixes a thing."))
        self.assertIn('POST /issues/7/labels {"labels": ["needs-screenshots"]}', out)
        self.assertIn("POST /issues/7/comments", out)
        self.assertIn('PATCH /pulls/7 {"state": "closed"}', out)

    def test_adding_screenshots_reopens_it(self):
        pr = self.base(
            body=f"## Before\n{A}\n## After\n{B}",
            state="closed",
            labels=[{"name": "needs-screenshots"}],
        )
        out = self.enforce(pr, action="edited")
        self.assertIn("DELETE /issues/7/labels/needs-screenshots", out)
        self.assertIn('PATCH /pulls/7 {"state": "open"}', out)

    def test_old_and_exempt_pull_requests_are_left_alone(self):
        for pr in (
            self.base(created_at="2026-10-20T00:00:00Z"),
            self.base(labels=[{"name": "no-screenshots"}]),
            self.base(head={"ref": "release/v0.2.134"}),
        ):
            self.assertNotIn("[dry-run]", self.enforce(pr))

    def test_a_pull_request_closed_by_hand_is_not_reopened(self):
        pr = self.base(body=f"## Before\n{A}\n## After\n{B}", state="closed")
        self.assertNotIn("[dry-run]", self.enforce(pr, action="edited"))

    def test_a_maintainer_reopen_overrides(self):
        pr = self.base(labels=[{"name": "needs-screenshots"}])
        out = self.enforce(pr, action="reopened", sender="maintainer")
        self.assertNotIn("closed", out.split("[dry-run]")[-1] if "[dry-run]" in out else "")
        self.assertNotIn('"state": "closed"', out)


if __name__ == "__main__":
    unittest.main()
