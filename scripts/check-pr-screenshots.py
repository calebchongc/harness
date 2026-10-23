#!/usr/bin/env python3
"""Require a before and an after screenshot in every pull request's description.

Run by .github/workflows/pr-screenshots.yml on pull request events. The check
fails until the description has an image under a "Before" label and one under
an "After" label (AGENTS.md, "Commits and pull requests"). Recognised forms:

    ## Before            **Before**           | Before | After |
    ![...](url)          <img src="url">      |---|---|
    ## After             **After:**           | ![](a) | ![](b) |
    ![...](url)          ![...](url)

An image whose alt text says "before" or "after" also counts.

Exempt: release pull requests (head `release/...`), bots, and pull requests a
maintainer labels `no-screenshots` (adding a label needs write access).

Usage: check-pr-screenshots.py [--event PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

EXEMPT_LABEL = "no-screenshots"
IMAGE = re.compile(
    r"!\[(?P<alt>[^\]]*)\]\(\s*<?[^)\s>]+>?(?:\s+\"[^\"]*\")?\s*\)"
    r"|<img\b(?P<attrs>[^>]*)>",
    re.IGNORECASE,
)
BEFORE = re.compile(r"\bbefore\b", re.IGNORECASE)
AFTER = re.compile(r"\bafter\b", re.IGNORECASE)
HEADING = re.compile(r"^\s*(#{1,6}\s|\*\*|__|<b>|<strong>|[^|!<]{0,40}:\s*$)")


def _strip_code(body: str) -> str:
    """Drop fenced and inline code, so an example in backticks doesn't count."""
    body = re.sub(r"```.*?```", "", body, flags=re.DOTALL)
    return re.sub(r"`[^`\n]*`", "", body)


def _label_of(text: str) -> str | None:
    has_before, has_after = bool(BEFORE.search(text)), bool(AFTER.search(text))
    if has_before and not has_after:
        return "before"
    if has_after and not has_before:
        return "after"
    return None


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def screenshots(body: str) -> dict[str, int]:
    """How many before and after images a description has."""
    found = {"before": 0, "after": 0}
    current: str | None = None
    columns: list[str | None] | None = None
    for line in _strip_code(body or "").splitlines():
        stripped = line.strip()
        if stripped.startswith("|"):
            cells = _cells(stripped)
            labels = [_label_of(cell) for cell in cells]
            if any(labels) and not any(IMAGE.search(cell) for cell in cells):
                columns = labels  # A header row such as | Before | After |.
                continue
            if columns and not all(set(c) <= set("-: ") for c in cells):
                for index, cell in enumerate(cells):
                    if IMAGE.search(cell) and index < len(columns) and columns[index]:
                        found[columns[index]] += len(IMAGE.findall(cell))
                continue
        else:
            columns = None
        matched_image = False
        for match in IMAGE.finditer(line):
            matched_image = True
            alt = match.group("alt")
            if alt is None:
                alt = " ".join(re.findall(r"\balt\s*=\s*[\"']([^\"']*)", match.group("attrs") or ""))
            label = _label_of(alt) or _label_of(line[: match.start()]) or current
            if label:
                found[label] += 1
        if not matched_image and stripped:
            label = _label_of(stripped)
            if label and (HEADING.match(stripped) or len(stripped) <= 60):
                current = label
            elif HEADING.match(stripped) and stripped.startswith("#"):
                current = None  # A new, unrelated section.
    return found


MESSAGE = (
    "Add a before and an after screenshot to the description: an image under "
    "a \"Before\" heading and one under \"After\" (a two-column | Before | After | "
    "table works too). Capture from made-up data, crop to what changed, and upload "
    "with scripts/issue-screenshot.sh <PR number> <images>. For a change with "
    "nothing to see, a maintainer can add the `no-screenshots` label."
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    args = parser.parse_args()
    with open(args.event, encoding="utf-8") as f:
        pr = json.load(f)["pull_request"]

    labels = {label["name"] for label in pr.get("labels") or []}
    head = (pr.get("head") or {}).get("ref") or ""
    if EXEMPT_LABEL in labels:
        print(f"Labelled {EXEMPT_LABEL}; no screenshots needed.")
        return 0
    if head.startswith("release/"):
        print("Release pull request; its parts carry the screenshots.")
        return 0
    if (pr.get("user") or {}).get("type") == "Bot":
        print("Opened by a bot; skipping.")
        return 0

    found = screenshots(pr.get("body") or "")
    print(f"Before images: {found['before']}, after images: {found['after']}.")
    if found["before"] and found["after"]:
        return 0
    missing = " and ".join(name for name in ("before", "after") if not found[name])
    print(f"::error title=Missing {missing} screenshot::{MESSAGE}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### Missing {missing} screenshot\n\n{MESSAGE}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
