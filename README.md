# Muni.fyi

A community-built, open source home for local public information. Muni brings
municipal records, maps, meetings, and services together so people can see what
is happening where they live and help improve how that information is presented.

The Ruby application collects data from public sources, normalizes it into
SQLite, and presents it through a web app and command-line tools. Cambridge,
Massachusetts is the launch city; Boston and the Charles River region are also
being developed. See [data and attribution](docs/DATA_AND_ATTRIBUTION.md) for
the distinction between Muni's code and upstream data. The iOS app and image
assets are withheld pending provenance review. Connected sign-in, Ask
conversations, report submission, attestations, and the operator view are
excluded until an independent identity system is ready.

Launch city: **Cambridge, MA**.

## The metaphor

| Concept | Class            | Role                                                        |
| ------- | ---------------- | ----------------------------------------------------------- |
| Source  | `Muni::Source`   | One per external API or page. Typed `pull` interface.       |
| Beat    | `Muni::Beat`     | A scheduled poll over a Source. Like a beat cop's route.    |
| Record  | `Muni::Record`   | A normalized row. Each Source emits one or more types.      |
| Command | `Muni::Command`  | A CLI action with a Question DSL and `-y` auto-accept.      |
| View    | `Muni::View`     | A web pane / widget descriptor.                             |
| Hall    | `Muni::Hall`     | A city configuration bundle. Sources are scoped to a Hall.  |
| Plat    | `Muni::Plat`     | A spatial layer (GeoJSON / vector tiles) used by map views. |

## Monorepo layout

```
core/      muni-core gem — the framework
cli/       muni-cli gem  — the `muni` binstub
www/       muni-www gem  — Sinatra web app
sources/   Cambridge and Boston collectors, autoloaded by the CLI/web
mcp/       MCP servers (Python; shell out to `muni`)
agents/    agent configs (citizen, ops)
data/      SQLite + migrations
bin/       dev scripts (setup, test-all, lint)
```

## Setup

```sh
# from a clean clone
./setup
export PATH="$PWD/.muni/bin:$PATH"
muni --version
bundle exec rake
./dev
```

No production credential is needed for the local app and public data
collectors. `./dev --no-collect` starts from an existing local database without
contacting the data sources.

`./setup` installs the Ruby bundle into `vendor/bundle`, creates local
wrappers for `muni` plus the launch collector commands in `.muni/bin`, removes
stale `muni-get-*` wrappers, verifies SQLite, and migrates `data/db/muni.sqlite3`.

The launch collector commands are intentionally limited to:

- `muni-get-311`
- `muni-get-police`
- `muni-get-permits`
- `muni-get-crashes`
- `muni-get-trees`
- `muni-get-parks`
- `muni-get-food-trucks`
- `muni-get-transit`

`./dev` runs the local loop: migrate SQLite, seed every source for both Cambridge
and Boston from the shared Beat catalog, compute each Hall's analytics and
Digest, start the recurring scheduler, and serve one web UI with both
municipalities. The preferred URLs are `http://127.0.0.1:4567/?hall=cambridge`
and `http://127.0.0.1:4567/?hall=boston`; when that port is busy, `./dev`
chooses the next free port and prints the actual URL. Use `./dev --strict-port`
or `MUNI_DEV_AUTO_PORT=0` when you want a busy preferred port to fail fast.
Initial collection is a full retained-window/inventory seed and can take several
minutes on a fresh machine. Use `./dev --no-collect` when reusing an existing
database, or `MUNI_DEV_HALLS=cambridge` to intentionally run only one Hall.

## Common commands

```sh
muni halls                          # list configured cities
muni halls show cambridge

# Normalized domain fetch (live API by default; --cached reads SQLite)
muni get list
muni-get-311 cambridge,ma --since 24h --persist --json -y
muni-get-police cambridge,ma --since 24h --persist --json -y
muni-get-permits cambridge,ma --since 7d --persist --json -y
muni-get-crashes cambridge,ma --persist --json -y
muni-get-trees cambridge,ma --persist --json -y
muni-get-parks cambridge,ma --persist --json -y
muni-get-food-trucks cambridge,ma --persist --json -y
muni-get-transit --hall=cambridge --json
muni-get-transit --station=place-hvd
muni-get-transit --performance --hall=boston

# Zone: positional `cambridge,ma`, `--zone` / `--city`, or MUNI_ZONE=cambridge.
# Add only these collector commands to cron with `--persist`.

muni sources                        # registered sources
muni sources fetch cambridge/service_requests --since=1h --json

muni beats                          # list beats + cadence + last run
muni beats run cambridge/service_requests
muni beats serve                    # boot the supervisor loop
muni beats tail                     # follow the beats log

muni records ls service_requests --hall=cambridge --limit=5 --json
muni records show service_requests --id=14046744

muni data migrate                   # apply Sequel migrations
muni data status                    # table row counts + source cursors
muni serve                          # boot Sinatra on :4567
```

Every command supports `--json` for machine output and `-y` for non-interactive runs. When STDIN is not a TTY, `-y` is assumed.

## Architecture note

Sources and typed records are the shared core. The canonical ingestion surface
is the launch collector commands listed above, each run with `--persist`.
They can be run manually, from cron, or by the optional beats scheduler. The
web app is read-only and serves list/map views from `Muni::Store`.

See [docs/CAMBRIDGE_BASELINE.md](docs/CAMBRIDGE_BASELINE.md) for the launch
source list and future-source criteria.

## Self-hosting

You can run Muni locally with `./setup` and `./dev` without a Fly account.
For an independent deployment, use your own app name, domain, persistent SQLite
volume, credentials, and map provider. Check each data source's terms and rate
limits. Start with [self-hosting guidance](docs/SELF_HOSTING.md).

## License

Muni's original code is MIT licensed. See [LICENSE](LICENSE). Public datasets,
map data, and third-party assets have their own terms; see
[data and attribution](docs/DATA_AND_ATTRIBUTION.md). The Muni.fyi name is
distinct from the code license; independent deployments should not imply
endorsement by this project.

## Contribute

Muni is for people who use municipal information, as well as developers.
Reports of confusing labels, missing context, accessibility problems, stale
data, and hard-to-find source records are useful contributions. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow and source criteria,
and [GOVERNANCE.md](GOVERNANCE.md) for how community proposals are reviewed.
See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community expectations.
Report security concerns privately using [SECURITY.md](SECURITY.md). The [public release gate](docs/PUBLIC_RELEASE_GATE.md) records decisions pending before repository visibility changes.

## MBTA Transit Tracking & Performance (TeaTrak)

Muni integrates the real-time vehicle radar, station arrival boards, and historical punctuality tracking functionality of the **TeaTrak** project into a unified municipal transit interface under `/transit`.

- **Web Application Integration**:
  - The compiled production React + Canvas bundle from TeaTrak is mounted directly inside Muni's web shell (`www/views/transit.erb`) within `#root.transit-viewport`.
  - The view maintains Muni's persistent navigation rail, top bar, and municipality switcher (`/?hall=cambridge` and `/?hall=boston`), preventing viewport clipping and double scrollbars.
- **Municipality Scoping & Live Map**:
  - The live map visualizes the entire Greater Boston MBTA system (Red, Orange, Blue, Green Line branches B/C/D/E, Mattapan Trolley, and Commuter Rail lines) while dynamically highlighting stations belonging to the active municipality (`window.MUNI_HALL`).
  - Cambridge stations (Alewife, Porter, Harvard, Central, Kendall/MIT, Lechmere) are highlighted in emerald green with `🏛️` tags, while Boston stations receive glowing blue halos with `🏙️` tags.
- **On-Time Performance (OTP) & Benchmarks**:
  - The statistics dashboard provides corridor-level breakdown filters for **Cambridge Corridors** (Red Line, Fitchburg Line, Green D/E), **Boston Corridors** (Subway lines, Commuter Rail network), and an **All MBTA System** overview with slow-zone removal progress and delay causes.
- **Opt-In Audio & Notifications**:
  - Audio train arrival chimes (`TransitChimeSynth`) default strictly to **muted**. Chimes only play if the user explicitly un-mutes audio via the top-bar button.
  - Browser notifications for home stations strictly check `Notification.permission === 'granted'` and require an explicit opt-in button click before requesting system notification permissions.
- **API & Station Aliasing**:
  - Upstream queries use MBTA V3 API open endpoints anonymously without hardcoded keys. An optional `MBTA_API_KEY` environment variable can be set for higher rate limits (1,000 req/min).
  - Bidirectional alias mapping in `Muni::Transit::Stations` bridges standard MBTA GTFS IDs (e.g. `place-cntrm`, `place-coecl`) with canvas coordinate placeholders (e.g. `place-[#00000]`, `place-[#00006]`).
- **Endpoints & CLI**:
  - Web: `GET /transit?hall=cambridge`, `GET /transit?hall=boston`
  - REST: `GET /api/transit/stations(.geojson)`, `/api/transit/performance`, `/api/transit/predictions/:stop_id`, `/api/transit/alerts`
  - CLI: `muni-get-transit [--hall=...] [--station=...] [--performance] [--alerts] [--json]`
  - MCP: `regional_transit_stations`, `regional_transit_performance`, `regional_transit_arrivals`, `regional_transit_alerts` in `mcp/regional/server.py`.

## Water Quality (optional)

Set `MUNI_WATER_ENABLED=1` to enable the Charles River region, linked from Cambridge and Boston. Seed once with `bundle exec muni beats seed --waterbody=charles --json`, then run the usual Beat scheduler. Open `/water/charles` for Metrics, Map, Records, and Datasets. Old city water URLs redirect to the region.

See [Water Quality operations and methodology](docs/WATER_QUALITY.md) for source schedules, retained evidence, reviewed advisory imports, APIs, verification, and backup behavior. Production deployment is separate.
