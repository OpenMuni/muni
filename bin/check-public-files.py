#!/usr/bin/env python3
"""Reject accidentally committed private deployment material by path."""
import fnmatch
import subprocess

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
patterns = ["*.env", ".env", ".env.*", "*.sqlite3*", "*.db", "*.tfstate*", "*.tfvars*",
            "*.tfplan", "*.pem", "*.key", "*.p12", "*.pfx", "runtime.conf"]
prefixes = ("deploy/aws/", "docs/AWS_MIGRATION.md", "data/backups/", "data/report_media/",
            ".agents/", ".codex/")
bad = []
for path in filter(None, paths):
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".example"):
        continue
    if path.startswith(prefixes) or any(fnmatch.fnmatch(name, pattern) for pattern in patterns):
        bad.append(path)
if bad:
    raise SystemExit("Private/generated material must not be committed:\n" + "\n".join(bad))
print("Tracked paths contain no private deployment files or databases.")
