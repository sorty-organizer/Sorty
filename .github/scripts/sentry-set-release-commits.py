#!/usr/bin/env python3
"""Attach the commits between the previous release tag and HEAD to a Sentry release.

Used by the release workflow instead of `sentry-cli releases set-commits --auto`,
which diffs against whatever Sentry release came last (often a local candidate)
and attached only two commits to 1.2.1. Requires SENTRY_AUTH_TOKEN and SENTRY_ORG,
and a checkout with full history and tags.

Usage: sentry-set-release-commits.py <release-version>
"""

import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

# Sentry keeps at most this many commits per release.
MAX_COMMITS = 1000


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def previous_tag() -> str | None:
    """Returns the newest v* tag reachable from HEAD that is not on HEAD itself."""
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD^")
    except subprocess.CalledProcessError:
        return None


def main() -> None:
    release = sys.argv[1]
    base = previous_tag()
    revision_range = f"{base}..HEAD" if base else "HEAD"
    lines = git(
        "log", f"--max-count={MAX_COMMITS}", "--format=%H%x1f%an%x1f%ae%x1f%cI%x1f%s", revision_range
    ).splitlines()
    keys = ["id", "author_name", "author_email", "timestamp", "message"]
    commits = [dict(zip(keys, line.split("\x1f")), repository="origin") for line in lines if line]
    if not commits:
        sys.exit(f"No commits found in {revision_range}")

    url = (
        f"https://sentry.io/api/0/organizations/{os.environ['SENTRY_ORG']}/releases/"
        f"{urllib.parse.quote(release, safe='')}/"
    )
    request = urllib.request.Request(
        url,
        data=json.dumps({"commits": commits}).encode(),
        method="PUT",
        headers={
            "Authorization": f"Bearer {os.environ['SENTRY_AUTH_TOKEN']}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        count = json.load(response)["commitCount"]
    print(f"Attached {count} commits ({revision_range}) to {release}")
    if count != len(commits):
        sys.exit(f"Sentry recorded {count} commits, expected {len(commits)}")


if __name__ == "__main__":
    main()
