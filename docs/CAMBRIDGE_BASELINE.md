# Cambridge Baseline

Muni.fyi launches on one municipality: Cambridge, Massachusetts. Each launch
resource is official, structured, and repeatable through one of the launch
collector commands with `--persist`, or through the matching beat. No other
collectors are part of the MVP command surface.

| Resource | Command | Source | Cadence | UI |
| --- | --- | --- | --- | --- |
| 311 service requests | `muni-get-311 cambridge,ma --persist --json -y` | SeeClickFix Open311 live feed; Socrata `2z9k-mv9g` fallback/backfill | 5 minutes | list + map |
| Police daily log | `muni-get-police cambridge,ma --persist --json -y` | Daily Police Log (`3gki-wyrb`) | 1 hour | list + map |
| Building permits | `muni-get-permits cambridge,ma --persist --json -y` | Building Permits: Addition/Alteration (`qu2z-8suj`) | 6 hours | list + map |
| Crashes | `muni-get-crashes cambridge,ma --persist --json -y` | Police Department Crash Data - Updated (`gb5w-yva3`) | 6 hours | list + map |
| Street trees | `muni-get-trees cambridge,ma --persist --json -y` | Street Trees (`82zb-7qc9`) | 12 hours | list + map |
| Food trucks | `muni-get-food-trucks cambridge,ma --persist --json -y` | Mobile Food Truck Permits (`qweb-m8r8`) | 12 hours | list + map |

## Selection Rules

- Prefer official Cambridge Open Data / Socrata datasets with stable resource IDs.
- Prefer rows with durable external IDs and timestamps.
- Prefer point geometry for map views; approximate map points are acceptable
  when the official dataset provides street/intersection text instead of exact
  coordinates.
- Avoid high-frequency non-Cambridge feeds, scraped pages, or key-gated APIs until a
  Cambridge operational use case requires them.
- Run 311 near-live and police launch beats hourly with overlap windows. Permits and
  crashes run every 6 hours, and trees run every 12 hours. Upserts keep
  duplicate rows cheap while reducing the chance of missing late-arriving source
  updates.
- Keep recurring collection small by default. Beats use conservative batch
  limits: 311 `1000`, police `500`, permits `500`, crashes `1000`, trees
  `1000`, and food trucks `500`.
- Inventory-style sources without timestamps must page forward with a durable
  cursor instead of re-pulling a whole dataset. Street trees use an offset
  cursor and cycle through the inventory gradually.

## Current Gaps

- Crash data comes from Cambridge's updated official crash dataset. It is still
  a delayed safety feed rather than a live incident stream; Cambridge currently
  lists it as quarterly.
- Police log rows may be exact points when the source supplies geometry, or
  approximate street/intersection points resolved from text. Public Nominatim is
  disabled by default; use a contracted or self-hosted geocoder for recurring
  high-volume fallback geocoding.
- Street trees are refreshed in small offset-cursor batches. A complete local
  backfill is intentionally manual so the hourly service stays gentle.
- Set `SOCRATA_APP_TOKEN` in production to improve API reliability and quota.
- SQLite on a Fly volume is intentionally single-writer. Do not horizontally
  scale the `web` process until Muni.fyi moves to LiteFS, Postgres, or another
  replication story.

## Future Candidates

- City Council and committee agendas, if an official structured feed is exposed.
- City budget, spending, contracts, and procurement, once a stable API source is identified.
- Parking, traffic, street closures, and construction disruptions from official feeds.
- Inspectional Services permit families beyond addition/alteration.
- Parks, facilities, and capital projects when they have stable IDs and geometry.
