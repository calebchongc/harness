#!/usr/bin/env python3
"""Check that a new or edited issue carries an image, and that it shows the issue.

Run by .github/workflows/issue-image.yml on `issues` events. Every issue opens
with an image of what's wrong or what should change (AGENTS.md, "Issue format").

- No image: label the issue `needs-image` and leave one comment saying so.
- An image, and TYPESAFE_API_KEY set: ask TypeSafe's System One model two yes/no
  questions about the first image: does it show what the issue describes, and
  does it show private details. Either outcome updates the same comment.

The check is advisory: it labels and comments, and never fails the run over a
model or network error. The issue body is untrusted, so it is read from the
event file, never interpolated into a shell command, and images are only
fetched from GitHub's own hosts.

Usage: check-issue-image.py [--dry-run] [--event PATH]
  --dry-run prints what it would do instead of calling the GitHub API.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

MARKER = "<!-- issue-image-check -->"
NEEDS_IMAGE = "needs-image"
IMAGE_UNCLEAR = "image-unclear"
# `sync`'s comment argument: leave the bot comment as it is.
KEEP = object()
TYPESAFE_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"

# Hosts an issue's images are uploaded to: drag-and-drop attachments and
# scripts/issue-screenshot.sh (raw.githubusercontent.com).
IMAGE_HOSTS = ("github.com", "githubusercontent.com")
MAX_IMAGE_BYTES = 16 * 1024 * 1024
MIN_SIDE, MAX_SIDE = 280, 1568
# Below this, the image probably doesn't show the issue; above PRIVATE_AT, it
# probably shows something private.
SHOWS_ISSUE_AT = 0.3
PRIVATE_AT = 0.7
BODY_CHARS = 4000

MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
HTML_IMAGE = re.compile(r"<img\b[^>]*?\bsrc\s*=\s*[\"']([^\"']+)[\"']", re.IGNORECASE)


def image_urls(body: str) -> list[str]:
    """Image URLs in an issue body, in order, without duplicates."""
    found = [(m.start(), m.group(1)) for m in MARKDOWN_IMAGE.finditer(body)]
    found += [(m.start(), m.group(1)) for m in HTML_IMAGE.finditer(body)]
    urls: list[str] = []
    for _, url in sorted(found):
        if url not in urls:
            urls.append(url)
    return urls


def github_hosted(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    return parts.scheme == "https" and any(
        host == h or host.endswith("." + h) for h in IMAGE_HOSTS
    )


def without_images(body: str) -> str:
    """The body as text for the model: images are sent separately."""
    text = HTML_IMAGE.sub("", MARKDOWN_IMAGE.sub("[image]", body))
    text = re.sub(r"<img\b[^>]*>", "[image]", text, flags=re.IGNORECASE)
    return text.strip()[:BODY_CHARS]


def fetch_image(url: str, token: str | None) -> bytes:
    """Download an image, anonymously first; GitHub's own token only if refused."""
    try:
        return _download(url, None)
    except urllib.error.HTTPError as error:
        if not token or error.code not in (401, 403, 404):
            raise
    return _download(url, token)


def _download(url: str, token: str | None) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "harness-issue-image-check"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        final = response.geturl()
        if not github_hosted(final):
            raise ValueError(f"image redirected off GitHub to {urllib.parse.urlsplit(final).hostname}")
        data = response.read(MAX_IMAGE_BYTES + 1)
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("image is larger than 16 MiB")
    return data


def prepare_image(data: bytes) -> tuple[str, str]:
    """Fit an image to TypeSafe's limits; returns (format, base64)."""
    from PIL import Image

    image = Image.open(io.BytesIO(data))
    image.seek(0)
    image = image.convert("RGB")
    width, height = image.size
    scale = min(1.0, MAX_SIDE / max(width, height))
    if scale < 1.0:
        width, height = max(1, round(width * scale)), max(1, round(height * scale))
        image = image.resize((width, height), Image.LANCZOS)
    if width < MIN_SIDE or height < MIN_SIDE:
        # Pad rather than stretch a small crop up to the minimum side.
        canvas = Image.new("RGB", (max(width, MIN_SIDE), max(height, MIN_SIDE)), "white")
        canvas.paste(image, (0, 0))
        image = canvas
    out = io.BytesIO()
    image.save(out, format="PNG", optimize=True)
    return "png", base64.b64encode(out.getvalue()).decode("ascii")


def ask_typesafe(api_key: str, title: str, body: str, fmt: str, data_b64: str) -> dict[str, float]:
    ref = f"{uuid.uuid4()}-screenshot"
    request_body = {
        "model": MODEL,
        "state": {
            "issue": {"title": title, "body": body},
            "screenshot": ref,
        },
        "assets": {ref: {"type": "image", "format": fmt, "data_base64": data_b64}},
        "questions": {
            "shows_issue": {
                "type": "noul",
                "instructions": (
                    "Does `screenshot` show the problem, screen or change that "
                    "`issue` describes, in the app or tool the issue is about?"
                ),
            },
            "private": {
                "type": "noul",
                "instructions": (
                    "Does `screenshot` show private details: an email address, "
                    "a person's name or account, an API key or token, a local "
                    "file path with a user name in it, or the text of a private "
                    "conversation?"
                ),
            },
        },
    }
    request = urllib.request.Request(
        TYPESAFE_URL,
        data=json.dumps(request_body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "TypeSafe-Danger-Zone-Images": "true",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        answers = json.load(response)["answers"]
    return {name: float(answers[name]["noul"]) for name in ("shows_issue", "private")}


def verdict(urls: list[str], answers: dict[str, float] | None) -> tuple[set[str], str | None]:
    """Labels the issue should carry and the comment to show (None: no comment)."""
    if not urls:
        return {NEEDS_IMAGE}, (
            "This issue has no image. Every issue here includes one: a screenshot "
            "of what's wrong, or a picture of the change you'd like (a mockup or "
            "an annotated screenshot is fine). Edit the issue to add it, and this "
            "check runs again.\n\nCapture from made-up data, not your real chats, "
            "and crop to the part that matters. See AGENTS.md, \"Issue format\"."
        )
    if answers is None:
        return set(), None
    labels: set[str] = set()
    notes = []
    if answers["shows_issue"] < SHOWS_ISSUE_AT:
        labels.add(IMAGE_UNCLEAR)
        notes.append(
            "The first image doesn't seem to show what the issue describes. "
            "If it does, a note on what to look at helps; otherwise, add a "
            "screenshot of the problem or a picture of the change."
        )
    if answers["private"] > PRIVATE_AT:
        notes.append(
            "The first image may show private details (an email, a name, a key or "
            "token, a local path, or private conversation text). This repository "
            "is public: please check it, and replace it with a capture from "
            "made-up data if so. Editing the issue keeps the old image in its "
            "history, so delete and re-file if something sensitive was posted."
        )
    return labels, ("\n\n".join(notes) if notes else None)


class GitHub:
    def __init__(self, repo: str, token: str, dry_run: bool):
        self.repo, self.token, self.dry_run = repo, token, dry_run

    def call(self, method: str, path: str, payload=None):
        if self.dry_run and (method != "GET" or not self.token):
            if method != "GET":
                print(f"[dry-run] {method} {path} {json.dumps(payload) if payload else ''}")
            return None
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}{path}",
            data=json.dumps(payload).encode("utf-8") if payload is not None else None,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "User-Agent": "harness-issue-image-check",
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

    def ensure_label(self, name: str, color: str, description: str):
        try:
            self.call("GET", f"/labels/{urllib.parse.quote(name)}")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            self.call("POST", "/labels", {"name": name, "color": color, "description": description})

    def sync(self, number: int, current: set[str], wanted: set[str], comment: str | None):
        managed = {NEEDS_IMAGE, IMAGE_UNCLEAR}
        for name in sorted((wanted - current) & managed):
            self.ensure_label(
                name,
                "d93f0b" if name == NEEDS_IMAGE else "fbca04",
                "Issue has no image" if name == NEEDS_IMAGE else "Image may not show the issue",
            )
            self.call("POST", f"/issues/{number}/labels", {"labels": [name]})
        for name in sorted((current - wanted) & managed):
            self.call("DELETE", f"/issues/{number}/labels/{urllib.parse.quote(name)}")

        if comment is KEEP:
            return
        existing = None
        if not self.dry_run or self.token:
            comments = self.call("GET", f"/issues/{number}/comments?per_page=100") or []
            existing = next((c for c in comments if MARKER in (c.get("body") or "")), None)
        if comment:
            body = f"{MARKER}\n{comment}"
            if existing is None:
                self.call("POST", f"/issues/{number}/comments", {"body": body})
            elif existing["body"] != body:
                self.call("PATCH", f"/issues/comments/{existing['id']}", {"body": body})
        elif existing is not None:
            self.call("DELETE", f"/issues/comments/{existing['id']}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    args = parser.parse_args()

    with open(args.event, encoding="utf-8") as f:
        event = json.load(f)
    issue = event["issue"]
    if issue.get("pull_request"):
        return 0
    if (issue.get("user") or {}).get("type") == "Bot":
        print("Issue opened by a bot; skipping.")
        return 0

    title = issue.get("title") or ""
    body = issue.get("body") or ""
    number = issue["number"]
    current = {label["name"] for label in issue.get("labels") or []}
    token = os.environ.get("GITHUB_TOKEN", "")
    api_key = os.environ.get("TYPESAFE_API_KEY", "")

    urls = image_urls(body)
    print(f"Issue #{number}: {len(urls)} image(s).")
    answers = None
    if urls and api_key:
        url = urls[0]
        try:
            if not github_hosted(url):
                raise ValueError(f"image isn't hosted on GitHub ({urllib.parse.urlsplit(url).hostname})")
            fmt, data_b64 = prepare_image(fetch_image(url, token or None))
            answers = ask_typesafe(api_key, title, without_images(body), fmt, data_b64)
            print(f"shows_issue={answers['shows_issue']:.2f} private={answers['private']:.2f}")
        except Exception as error:  # Advisory: never fail the run over the model.
            print(f"::warning::Image check skipped: {error}")
    elif urls:
        print("TYPESAFE_API_KEY isn't set; only checking that an image is present.")

    labels, comment = verdict(urls, answers)
    if answers is None and urls and api_key:
        # The model couldn't be asked this time: keep its earlier verdict (label
        # and comment) rather than clearing it, and only drop `needs-image`.
        labels = current & {IMAGE_UNCLEAR}
        if NEEDS_IMAGE not in current:
            comment = KEEP
    GitHub(os.environ.get("GITHUB_REPOSITORY", ""), token, args.dry_run).sync(
        number, current, labels, comment
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
