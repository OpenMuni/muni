"""Regional MBTA subway tools backed by the standalone Muni transit CLI."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from mcp.server.mcpserver import MCPServer

ROOT = Path(__file__).resolve().parents[2]
mcp = MCPServer("muni-regional")


def transit(*args: str) -> str:
    command = ["bundle", "exec", str(ROOT / "cli" / "exe" / "muni-get-transit"), *args, "--json"]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "MBTA data unavailable")
    return json.dumps(json.loads(result.stdout))


@mcp.tool()
def regional_transit_stations() -> str:
    """List canonical parent stations and their MBTA rapid-transit routes."""
    return transit()


@mcp.tool()
def regional_transit_vehicles() -> str:
    """List live MBTA subway vehicles and their fetch time."""
    return transit("--vehicles")


@mcp.tool()
def regional_transit_arrivals(station_id: str) -> str:
    """Get live arrival predictions for a canonical MBTA station ID."""
    return transit("--station", station_id)


@mcp.tool()
def regional_transit_alerts() -> str:
    """Get current subway service alerts."""
    return transit("--alerts")


if __name__ == "__main__":
    mcp.run()
