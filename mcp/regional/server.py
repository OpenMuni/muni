"""Muni Regional MCP server (MBTA Transit & Charles River)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _shared import run  # noqa: E402

try:
    from mcp.server.mcpserver import MCPServer
    mcp = MCPServer("muni-regional")
except ImportError:
    mcp = None


def _register_tools():
    if not mcp:
        return

    @mcp.tool()
    def regional_transit_stations(hall: str | None = None) -> str:
        """List MBTA Rapid Transit and Commuter Rail stations, optionally scoped to Cambridge or Boston."""
        args = ["get", "transit"]
        if hall:
            args.extend(["--hall", hall])
        return json.dumps(run(*args))

    @mcp.tool()
    def regional_transit_performance(hall: str | None = None) -> str:
        """Retrieve MBTA On-Time Performance (OTP), punctuality benchmarks, and delay metrics."""
        args = ["get", "transit", "--performance"]
        if hall:
            args.extend(["--hall", hall])
        return json.dumps(run(*args))

    @mcp.tool()
    def regional_transit_arrivals(station_id: str) -> str:
        """Fetch live arrival and departure predictions for an MBTA station."""
        return json.dumps(run("get", "transit", f"--station={station_id}"))

    @mcp.tool()
    def regional_transit_alerts() -> str:
        """Fetch active MBTA systemwide service alerts and disruption advisories."""
        return json.dumps(run("get", "transit", "--alerts"))


_register_tools()
