#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""LinkLite download and traffic statistics from the GitHub API.

    scripts/download-stats.py                  # print downloads per release, and traffic
    scripts/download-stats.py --record DIR     # also upsert today's numbers into DIR/*.csv

GitHub keeps an all-time download count per release asset, with no history, and repository
traffic (views, clones) for 14 days only. --record keeps both: one row per asset per day in
downloads.csv, and one row per day in traffic.csv, so trends survive GitHub's window.

Counts include automatic updates, because Sparkle downloads the same release DMG, and any
manual re-downloads (for example release verification). Reading traffic needs a token with
push access to the repository; without it traffic is skipped.

Token: $GH_TOKEN or $GITHUB_TOKEN, else `gh auth token`. Standard library only.
"""
import argparse
import csv
import datetime
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = "matthewrball/linklite"
API = "https://api.github.com/repos/" + REPO


def token():
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name):
            return os.environ[name]
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def get(path, auth):
    request = urllib.request.Request(API + path, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        **({"Authorization": "Bearer " + auth} if auth else {}),
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def releases(auth):
    page, out = 1, []
    while True:
        batch = get(f"/releases?per_page=100&page={page}", auth)
        out += batch
        if len(batch) < 100:
            return out
        page += 1


def kind(asset):
    """The app itself (dmg/zip), its source archive, or a checksum."""
    name = asset["name"]
    if name.endswith(".sha256"):
        return "checksum"
    if "-source." in name:
        return "source"
    return "app"


def traffic(auth):
    """Daily views and clones for GitHub's 14-day window, or None without push access."""
    try:
        views = get("/traffic/views", auth)
        clones = get("/traffic/clones", auth)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            return None
        raise
    days = {}
    for key, data in (("views", views["views"]), ("clones", clones["clones"])):
        for day in data:
            date = day["timestamp"][:10]
            days.setdefault(date, {})[key] = (day["count"], day["uniques"])
    return days


def upsert(path, key_fields, rows, fields):
    """Replace rows with the same key, keep the rest, write sorted."""
    existing = {}
    if path.exists():
        with path.open(newline="") as f:
            for row in csv.DictReader(f):
                existing[tuple(row[k] for k in key_fields)] = row
    for row in rows:
        existing[tuple(str(row[k]) for k in key_fields)] = {k: str(row[k]) for k in fields}
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for key in sorted(existing):
            writer.writerow(existing[key])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--record", type=Path, metavar="DIR", help="upsert today's snapshot into DIR/*.csv")
    args = parser.parse_args()
    auth = token()
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()

    rels = releases(auth)
    print(f"{'release':<10} {'published':<11} {'app':>5} {'source':>6}")
    totals = {"app": 0, "source": 0}
    rows = []
    for rel in rels:
        counts = {"app": 0, "source": 0, "checksum": 0}
        for asset in rel["assets"]:
            counts[kind(asset)] += asset["download_count"]
            rows.append({"date": today, "release": rel["tag_name"], "asset": asset["name"],
                         "kind": kind(asset), "downloads": asset["download_count"]})
        totals["app"] += counts["app"]
        totals["source"] += counts["source"]
        print(f"{rel['tag_name']:<10} {(rel.get('published_at') or '')[:10]:<11} {counts['app']:>5} {counts['source']:>6}")
    print(f"{'total':<22} {totals['app']:>5} {totals['source']:>6}")
    print("(app = DMG/zip downloads, including automatic updates; source = source archives)")

    days = traffic(auth)
    if days is None:
        print("\nTraffic: skipped (needs a token with push access to the repository)")
    else:
        views = sum(d.get("views", (0, 0))[0] for d in days.values())
        clones = sum(d.get("clones", (0, 0))[0] for d in days.values())
        print(f"\nTraffic, last 14 days: {views} views, {clones} clones (per-day uniques are recorded with --record)")

    if args.record:
        args.record.mkdir(parents=True, exist_ok=True)
        upsert(args.record / "downloads.csv", ("date", "release", "asset"), rows,
               ["date", "release", "asset", "kind", "downloads"])
        if days:
            upsert(args.record / "traffic.csv", ("date",), [
                {"date": date, "views": d.get("views", (0, 0))[0], "view_uniques": d.get("views", (0, 0))[1],
                 "clones": d.get("clones", (0, 0))[0], "clone_uniques": d.get("clones", (0, 0))[1]}
                for date, d in days.items()
            ], ["date", "views", "view_uniques", "clones", "clone_uniques"])
        print(f"\nRecorded snapshot for {today} in {args.record}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
