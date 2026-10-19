"""Check that the locked SDK registers the existing tools without upstream calls."""
import asyncio
import runpy
from pathlib import Path

server = runpy.run_path(str(Path(__file__).parent / "cambridge" / "server.py"))["mcp"]
tools = asyncio.run(server.list_tools())
assert {tool.name for tool in tools} == {
    "cambridge_police_log", "cambridge_service_requests", "cambridge_building_permits",
    "cambridge_vision_zero", "cambridge_trees", "cambridge_city_digest_context",
}
print("All six MCP tools registered with the locked SDK.")

regional = runpy.run_path(str(Path(__file__).parent / "regional" / "server.py"))["mcp"]
regional_tools = asyncio.run(regional.list_tools())
assert {tool.name for tool in regional_tools} == {
    "regional_transit_stations", "regional_transit_vehicles",
    "regional_transit_arrivals", "regional_transit_alerts",
}
print("All four regional subway tools registered with the locked SDK.")
