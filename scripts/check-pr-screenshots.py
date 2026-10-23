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

Exempt: pull requests opened before the rule (ENFORCE_SINCE), release pull
requests (head `release/...`), bots, and pull requests a maintainer labels
`no-screenshots` (adding a label needs write access).

Two modes, one per workflow:
- the check (default): exits 1 when screenshots are missing, so the required
  `before-and-after` status blocks the merge;
- `--enforce` (pull_request_target, with write access): closes a new pull
  request that has none, with the `needs-screenshots` label and one comment,
  and reopens it once its description has both.

Usage: check-pr-screenshots.py [--enforce] [--dry-run] [--event PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

EXEMPT_LABEL = "no-screenshots"
CLOSED_LABEL = "needs-screenshots"
MARKER = "<!-- pr-screenshots-check -->"
# Pull requests opened before the rule existed aren't checked.
ENFORCE_SINCE = "2026-10-23T06:30:00Z"
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


def exemption(pr: dict) -> str | None:
    """Why a pull request needs no screenshots, or None."""
    labels = {label["name"] for label in pr.get("labels") or []}
    if EXEMPT_LABEL in labels:
        return f"Labelled {EXEMPT_LABEL}; no screenshots needed."
    if ((pr.get("head") or {}).get("ref") or "").startswith("release/"):
        return "Release pull request; its parts carry the screenshots."
    if (pr.get("user") or {}).get("type") == "Bot":
        return "Opened by a bot; skipping."
    if (pr.get("created_at") or "") < ENFORCE_SINCE:
        return "Opened before the screenshot rule; skipping."
    return None


def missing(pr: dict) -> str | None:
    """'before', 'after' or 'before and after' when screenshots are missing."""
    found = screenshots(pr.get("body") or "")
    print(f"Before images: {found['before']}, after images: {found['after']}.")
    gaps = [name for name in ("before", "after") if not found[name]]
    return " and ".join(gaps) or None


def github(method: str, path: str, payload=None, dry_run: bool = False):
    import urllib.error
    import urllib.request

    if dry_run:
        if method != "GET":
            print(f"[dry-run] {method} {path} {json.dumps(payload) if payload else ''}")
        return None
    request = urllib.request.Request(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}{path}",
        data=json.dumps(payload).encode("utf-8") if payload is not None else None,
        headers={
            "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "harness-pr-screenshots",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        if method == "DELETE" and error.code == 404:
            return None
        raise


def enforce(event: dict, pr: dict, dry_run: bool) -> int:
    number = pr["number"]
    labels = {label["name"] for label in pr.get("labels") or []}
    closed_by_check = CLOSED_LABEL in labels
    gap = None if exemption(pr) else missing(pr)

    def bot_comment():
        if dry_run:
            return None
        comments = github("GET", f"/issues/{number}/comments?per_page=100") or []
        return next((c for c in comments if MARKER in (c.get("body") or "")), None)

    if gap is None:
        if closed_by_check:
            github("DELETE", f"/issues/{number}/labels/{CLOSED_LABEL}", dry_run=dry_run)
            if pr.get("state") == "closed" and not pr.get("merged"):
                github("PATCH", f"/pulls/{number}", {"state": "open"}, dry_run)
                print(f"Reopened #{number}: it has its screenshots now.")
            existing = bot_comment()
            if existing:
                github("DELETE", f"/issues/comments/{existing['id']}", dry_run=dry_run)
        return 0

    if pr.get("state") == "closed":
        return 0
    if event.get("action") == "reopened" and (event.get("sender") or {}).get("login") != (
        pr.get("user") or {}
    ).get("login"):
        print(f"Reopened by {(event.get('sender') or {}).get('login')}; leaving it open.")
        return 0
    body = (
        f"{MARKER}\nClosed because the description has no {gap} screenshot. "
        f"{MESSAGE}\n\nEdit the description to add them and this reopens on its own."
    )
    if not closed_by_check:
        github(
            "POST",
            f"/issues/{number}/labels",
            {"labels": [CLOSED_LABEL]},
            dry_run,
        )
    existing = bot_comment()
    if existing is None:
        github("POST", f"/issues/{number}/comments", {"body": body}, dry_run)
    elif existing["body"] != body:
        github("PATCH", f"/issues/comments/{existing['id']}", {"body": body}, dry_run)
    github("PATCH", f"/pulls/{number}", {"state": "closed"}, dry_run)
    print(f"Closed #{number}: missing {gap} screenshot.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    with open(args.event, encoding="utf-8") as f:
        event = json.load(f)
    pr = event["pull_request"]

    if args.enforce:
        return enforce(event, pr, args.dry_run)

    reason = exemption(pr)
    if reason:
        print(reason)
        return 0
    gap = missing(pr)
    if gap is None:
        return 0
    print(f"::error title=Missing {gap} screenshot::{MESSAGE}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### Missing {gap} screenshot\n\n{MESSAGE}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
