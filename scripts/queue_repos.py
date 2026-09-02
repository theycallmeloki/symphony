#!/usr/bin/env python3
"""Symphony repo queue scanner.

Discovers sibling git repositories with a remote pointing at a given GitHub
org (default theycallmeloki) and optionally queues each as a Symphony intent
(created in the `queued` state — they wait in the dashboard until you assign
a task and run).

Usage:
  queue_repos.py                     # list candidate repos (dry run)
  queue_repos.py --queue             # register each as a queued repo intent
  queue_repos.py --queue --run       # register as open (dispatch immediately)
  queue_repos.py --root ~/Documents  # scan a different root
  queue_repos.py --exclude llama.cpp,pachyderm

API connection: SYMPHONY_URL (default https://symphony.transparentlyrotatableproxy.site),
SYMPHONY_USER/SYMPHONY_PASS (default milady/milady). Requires basic auth.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_ORG = "theycallmeloki"
DEFAULT_ROOT = str(Path.home() / "Documents")
DEFAULT_URL = "https://symphony.transparentlyrotatableproxy.site"


def git(args, cwd):
    try:
        out = subprocess.run(
            ["git", "-C", str(cwd)] + args,
            capture_output=True,
            text=True,
            timeout=20,
        )
        return out.returncode, out.stdout.strip(), out.stderr.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return 1, "", "git unavailable"


def repo_remotes(path):
    code, out, _ = git(["remote", "-v"], path)
    if code != 0:
        return {}
    remotes = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            name, url = parts[0], parts[1]
            remotes.setdefault(name, set()).add(url)
    return remotes


def parse_owner(url):
    """Return the owner from an https or scp-style GitHub URL."""
    url = url.strip()
    if url.startswith("git@"):
        # git@github.com:theycallmeloki/repo.git
        host_path = url.split(":", 1)
        if len(host_path) == 2:
            path = host_path[1]
            parts = path.split("/")
            if len(parts) >= 2:
                return parts[0]
        return None
    parts = url.split("/")
    # https://github.com/<owner>/<repo>[.git]
    if len(parts) >= 5 and parts[2] == "github.com":
        return parts[3]
    return None


def discover(root, org, excludes):
    found = []
    for entry in sorted(Path(root).iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        if name in excludes:
            continue
        if not (entry / ".git").exists() and not (entry / ".git").is_dir():
            continue
        remotes = repo_remotes(entry)
        owners = {parse_owner(u) for urls in remotes.values() for u in urls}
        owners.discard(None)
        matched = [
            (rname, url) for rname, urls in remotes.items() for url in urls if parse_owner(url) == org
        ]
        if matched:
            origin = [u for n, u in matched if n == "origin"]
            primary = origin[0] if origin else matched[0][1]
            found.append({"name": name, "path": str(entry), "org": org, "remote": primary})
    return found


def canonical_https(url):
    owner_repo = url.strip().rstrip("/")
    if "github.com" not in owner_repo:
        return url
    # git@github.com:owner/repo.git -> https://github.com/owner/repo
    if owner_repo.startswith("git@"):
        path = owner_repo.split(":", 1)[1]
        return f"https://github.com/{path}"
    return owner_repo


def api_request(url, payload=None):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Content-Type": "application/json"},
        method="POST" if payload is not None else "GET",
    )
    user = os.environ.get("SYMPHONY_USER", "milady")
    password = os.environ.get("SYMPHONY_PASS", "milady")
    import base64

    req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def queue_repos(repos, state):
    base = os.environ.get("SYMPHONY_URL", DEFAULT_URL).rstrip("/")
    queued, errors = [], []
    for repo in repos:
        slug = repo["name"]
        payload = {
            "intent": {
                "state": state,
                "title": f"Repo job: {slug}",
                "repo": canonical_https(repo["remote"]),
                "labels": ["repo-queue"],
                "description": (
                    f"Queued repository job for {slug}. Assign a concrete task before activating: "
                    f"what should the agent build, change, verify, or report about this repository?"
                ),
            }
        }
        try:
            resp = api_request(f"{base}/api/v1/intents", payload)
            queued.append((slug, resp["intent"]["id"]))
        except (urllib.error.HTTPError, urllib.error.URLError, KeyError) as exc:
            errors.append((slug, str(exc)))
    return queued, errors


def main():
    parser = argparse.ArgumentParser(description="Discover + queue theycallmeloki sibling repos")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="directory to scan")
    parser.add_argument("--org", default=DEFAULT_ORG, help="github owner to match")
    parser.add_argument("--exclude", default="", help="comma-separated repo names to skip")
    parser.add_argument("--queue", action="store_true", help="register found repos as intents")
    parser.add_argument("--run", action="store_true", help="with --queue: register as open (auto-run)")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    excludes = {s.strip() for s in args.exclude.split(",") if s.strip()}
    repos = discover(args.root, args.org, excludes)
    state = "open" if args.run else "queued"

    if args.queue:
        queued, errors = queue_repos(repos, state)
        if args.json:
            print(json.dumps({"queued": queued, "errors": errors, "state": state}, indent=2))
            return 0
        for slug, intent_id in queued:
            print(f"queued  {slug:32s} {intent_id}")
        for slug, err in errors:
            print(f"failed  {slug:32s} {err}", file=sys.stderr)
        print(f"\n{len(queued)} repo intents registered as '{state}' ({len(errors)} failed)")
        return 0 if not errors else 1

    if args.json:
        print(json.dumps(repos, indent=2))
        return 0

    if not repos:
        print("No matching repos found.")
        return 0
    width = max(len(r["name"]) for r in repos)
    for repo in repos:
        flag = "*" if repo["remote"].endswith(".git") or "theycallmeloki" in repo["remote"] else " "
        print(f"{repo['name']:{width}}  {repo['remote']}")
    print(f"\n{len(repos)} repos with a {args.org} remote. Re-run with --queue to register them as intents.")


if __name__ == "__main__":
    sys.exit(main())
