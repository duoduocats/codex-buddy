#!/usr/bin/env python3
"""Maintainer-only public GitHub download counts; never runs in the app."""
import argparse
import csv
import json
import plistlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def download_stats(repository):
    """Count DMG downloads, not installations, devices or active users."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Use owner/repository")
    rows = []
    repository = "/".join(urllib.parse.quote(part, safe="") for part in repository.split("/"))
    for page in range(1, 21):
        request = urllib.request.Request(
            f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "Codex-Buddy-maintainer-download-stats"},
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(5_000_001)
            if len(raw) > 5_000_000:
                raise ValueError("GitHub response is too large")
            releases = json.loads(raw)
        if not isinstance(releases, list):
            raise ValueError("Unexpected GitHub response")
        for release in releases:
            if release.get("draft") or release.get("prerelease"):
                continue
            assets = release.get("assets", [])
            packages = [a for a in assets if str(a.get("name", "")).endswith(".dmg")]
            rows.append({
                "version": release["tag_name"],
                "dmg_downloads": sum(int(a.get("download_count", 0)) for a in packages),
                "published_at": release.get("published_at"),
                "url": release["html_url"],
            })
        if len(releases) < 100:
            return rows
    raise ValueError("More than 2,000 releases; narrow the repository")


def main():
    root = Path(__file__).resolve().parents[1]
    repository = plistlib.loads((root / "Info.plist").read_bytes())["GitHubRepository"]
    parser = argparse.ArgumentParser(description="Public DMG download counts, not active-user counts. No app telemetry.")
    parser.add_argument("--repo", default=repository, help="GitHub owner/repository")
    parser.add_argument("--format", choices=["table", "json", "csv"], default="table")
    args = parser.parse_args()
    try:
        rows = download_stats(args.repo)
    except (ValueError, KeyError, TypeError, urllib.error.URLError, TimeoutError) as error:
        if isinstance(error, urllib.error.HTTPError):
            print(f"GitHub returned HTTP {error.code}; try again later.", file=sys.stderr)
        else:
            print("Could not read public GitHub release counts. Check the repository and connection.", file=sys.stderr)
        return 1
    if args.format == "json":
        print(json.dumps({"metric": "dmg_downloads", "is_active_user_count": False, "releases": rows}, indent=2))
    elif args.format == "csv":
        writer = csv.DictWriter(sys.stdout, fieldnames=["version", "dmg_downloads", "published_at", "url"])
        writer.writeheader()
        writer.writerows(rows)
    else:
        print("Version       DMG downloads   Published (UTC)")
        for row in rows:
            print(f"{row['version']:<13} {row['dmg_downloads']:>12}   {row['published_at'] or '—'}")
        print("Downloads include repeats and updates; they do not measure active users or installed versions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
