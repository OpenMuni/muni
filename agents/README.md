# Muni agents

Two model-agnostic system prompts plus the MCP servers in `mcp/` that back
them. Drop them into Claude Desktop, Continue.dev, Cursor, or any host that
speaks MCP.

- `citizen.md` — public-facing concierge for residents.
- `ops.md` — operator dashboard for engineers.

## Wiring

Install the MCP SDK once:

```
python3 -m venv .venv
.venv/bin/pip install -r mcp/requirements.txt
```

Smoke-test the data plane (this exercises the same `bundle exec muni …
--json` calls the MCP server shells out to):

```
./mcp/test_servers.sh           # uses existing SQLite store
FRESH=1 ./mcp/test_servers.sh   # rebuilds + seeds Cambridge beats
```

Then run the server, or wire it through Claude Desktop:

```
.venv/bin/python mcp/cambridge/server.py
```

Example Claude Desktop `claude_desktop_config.json` snippet:

```json
{
  "mcpServers": {
    "muni-cambridge": { "command": "/path/to/muni/.venv/bin/python", "args": ["/path/to/muni/mcp/cambridge/server.py"] }
  }
}
```

Each tool shells out to `bundle exec muni records ls … --json -y` from the
repo root, so the `muni-core` data store stays the single source of truth.
Live collection stays outside MCP and uses the five launch collector commands:
`muni-get-311`, `muni-get-police`, `muni-get-permits`, `muni-get-crashes`, and
`muni-get-trees`.
