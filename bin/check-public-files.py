#!/usr/bin/env python3
"""Reject accidentally committed private deployment material by path."""
import fnmatch
import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
if "--history" in sys.argv:
    # Deleting a file from the tip does not remove it from public Git history.
    paths += subprocess.check_output(
        ["git", "log", "--all", "--format=", "--name-only", "-z"]
    ).decode().split("\0")
patterns = ["*.env", ".env", ".env.*", "*.sqlite3*", "*.db", "*.tfstate*", "*.tfvars*",
            "*.tfplan", "*.pem", "*.key", "*.p12", "*.pfx", "runtime.conf"]
prefixes = ("deploy/aws/", "docs/AWS_MIGRATION.md", "data/backups/", "data/report_media/",
            ".agents/", ".codex/")
bad = []
for path in sorted({path.strip("\n") for path in paths if path.strip("\n")}):
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".example"):
        continue
    if path.startswith(prefixes) or any(fnmatch.fnmatch(name, pattern) for pattern in patterns):
        bad.append(path)
if bad:
    raise SystemExit("Private/generated material must not be committed:\n" + "\n".join(bad))
print("Tracked paths contain no private deployment files or databases.")
