# Muni Development Guide

## Cursor Cloud specific instructions

### Environment

- Use Ruby 3.3.12, as pinned in `.ruby-version`. Install it with your Ruby version manager before running `./setup`.
- SQLite is the only database; no external DB server needed. Data lives in `data/db/muni.sqlite3`.
- The project is a Ruby monorepo with 3 sub-gems: `core/`, `cli/`, `www/`.

### Running services

- **Web app:** `bundle exec muni serve --bind=0.0.0.0 --port=4567` — starts Puma on :4567. Health: `GET /healthz`.
- **Beats scheduler:** `bundle exec muni beats serve` — polls external data sources on schedule.
- **Single beat run:** `bundle exec muni beats run <source_slug> --json` — e.g., `cambridge/service_requests`.
- The frontend uses Alpine.js/MapLibre loaded from CDN; no JS build step required. `package-lock.json` audits the CDN dependencies.

### Testing & Linting

- **Tests:** `bin/test-all` or `bundle exec rspec` (runs specs across all sub-gems).
- **Lint:** `bin/lint` or `bundle exec rubocop --no-server --cache false`.
- **Default Rake:** `bundle exec rake` runs both spec and lint.

### Gotchas

- Cambridge and Boston are configured halls. Routes use `/?hall=cambridge` or `/?hall=boston` (query params), not `/cambridge` or `/boston`.
- The `records ls` command expects the plural table name (e.g., `service_requests`, not `service_request`).
- Cambridge Socrata reads work anonymously with rate limits; set `SOCRATA_APP_TOKEN` for production quota.
- `./setup` installs the root bundle, creates `.muni/bin` wrappers for `muni`,
  `muni-get-311`, `muni-get-police`, `muni-get-permits`, `muni-get-crashes`,
  `muni-get-trees`, `muni-get-parks`, and prunes stale `muni-get-*` wrappers.
- Set `MUNI_SETUP_SUB_BUNDLES=1` only when you explicitly need each sub-gem's
  bundle installed separately.
