"""Shared helpers for Muni MCP servers.

Each server is a thin wrapper around the `muni` CLI: tools shell out, get JSON
back, and return it to the LLM. No business logic lives here — the source of
truth stays in `muni-core`.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent


def muni_bin() -> list[str]:
    """Locate the `muni` executable; prefer the repo's bundled binstub."""
    env = os.environ.get("MUNI_BIN")
    if env:
        return env.split()
    local = REPO_ROOT / "cli" / "exe" / "muni"
    if local.exists():
        return ["bundle", "exec", str(local)]
    found = shutil.which("muni")
    if found:
        return [found]
    raise RuntimeError("muni binary not found; set MUNI_BIN or `bundle exec` from repo root")


def run(*args: str) -> Any:
    """Invoke `muni …` with --json -y and return parsed JSON (or stdout text)."""
    cmd = [*muni_bin(), *args, "--json", "-y"]
    result = subprocess.run(
        cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"muni exited {result.returncode}: {result.stderr.strip() or result.stdout.strip()}"
        )
    out = result.stdout.strip()
    if not out:
        return []
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return out


def filter_rows(rows: list[dict], **filters: Any) -> list[dict]:
    """Loose case-insensitive substring filter for downstream MCP tool args."""
    def matches(row: dict) -> bool:
        for key, value in filters.items():
            if value in (None, ""):
                continue
            raw = row.get(key)
            if raw is None or value.lower() not in str(raw).lower():
                return False
        return True

    return [r for r in rows if matches(r)]
