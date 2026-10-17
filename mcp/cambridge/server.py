"""Muni Cambridge MCP server."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from _shared import filter_rows, run  # noqa: E402

from mcp.server.fastmcp import FastMCP  # noqa: E402

mcp = FastMCP("muni-cambridge")


@mcp.tool()
def cambridge_police_log(since: str = "24h", neighborhood: str | None = None) -> str:
    """Recent Cambridge Police daily log entries."""
    rows = run("records", "ls", "police_log_entrys", "--hall=cambridge",
               f"--since={since}", "--limit=100")
    rows = filter_rows(rows, neighborhood=neighborhood)
    return json.dumps(rows)


@mcp.tool()
def cambridge_service_requests(
    since: str = "1h", status: str | None = None, neighborhood: str | None = None
) -> str:
    """Recent Cambridge Commonwealth Connect / SeeClickFix tickets."""
    rows = run("records", "ls", "service_requests", "--hall=cambridge",
               f"--since={since}", "--limit=100")
    rows = filter_rows(rows, status=status, neighborhood=neighborhood)
    return json.dumps(rows)


@mcp.tool()
def cambridge_building_permits(since: str = "7d", permit_type: str | None = None) -> str:
    """Recent Cambridge issued permits."""
    rows = run("records", "ls", "building_permits", "--hall=cambridge",
               f"--since={since}", "--limit=100")
    rows = filter_rows(rows, permit_type=permit_type)
    return json.dumps(rows)


@mcp.tool()
def cambridge_vision_zero(since: str = "30d") -> str:
    """Cambridge historical crash records."""
    rows = run("records", "ls", "crashs", "--hall=cambridge", f"--since={since}", "--limit=200")
    return json.dumps(rows)


@mcp.tool()
def cambridge_trees(species: str | None = None, limit: int = 200) -> str:
    """Cambridge street tree inventory, optionally filtered by common name."""
    rows = run("records", "ls", "trees", "--hall=cambridge", f"--limit={limit}")
    rows = filter_rows(rows, species_common=species)
    return json.dumps(rows)


@mcp.tool()
def cambridge_city_digest_context() -> str:
    """Structured source facts used to generate the public Cambridge Digest."""
    payload = run("analytics", "digest-context", "--hall=cambridge")
    return json.dumps(payload)


if __name__ == "__main__":
    mcp.run()
