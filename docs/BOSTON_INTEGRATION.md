# Boston Integration and Operations

Boston is a read-only Hall backed directly by the official Analyze Boston CKAN
Action and DataStore APIs. The Boston sources emit only record types already
used by Cambridge: 311, crime, collisions, permits and development, zoning,
parking, trees, parks, food trucks, bicycle counts, construction Digest items,
and events. The Hall boundary is omitted from this source snapshot pending
dataset-specific redistribution review.

## Local two-city startup

Run `./setup` once and then `./dev`. The development launcher migrates the
shared SQLite database, runs the metadata-driven Hall seed for Cambridge and
Boston, starts the one-writer scheduler, and serves both municipalities from
the same process. Initial collection is intentionally completed before the UI
starts so a fresh machine does not open with one Hall still waiting for its
staggered scheduler slot. Use `./dev --no-collect` only when the local database
has already been seeded, or `MUNI_DEV_HALLS=cambridge` for an intentional
single-Hall session.

## Rollout

1. Back up the current database and verify the backup opens with
   `PRAGMA integrity_check` returning `ok`.
2. Deploy with `MUNI_PUBLIC_HALLS=cambridge`. The Hall exists for collection and
   backfill but is absent from `/api/halls`.
3. Run `bundle exec muni beats seed --hall=boston --json` on the one data-owning
   web Machine. Runs are idempotent: completed batches are Hall-scoped upserts,
   and a failed inventory never prunes rows.
4. Run analytics for Boston, verify `/api/categories?hall=boston`, and check that
   every citation points to `data.boston.gov`.
5. Soak for 24 hours. Require zero SQLite busy errors, no failed critical beats,
   peak RSS below 3 GB, database plus WAL below 10 GB, and p95 category list/map
   responses below 500 ms.
6. Set `MUNI_PUBLIC_HALLS=cambridge,boston`, deploy, and verify query-param and
   `boston.muni.fyi` routing. Invalid explicit Halls must return 404.

Production uses one `shared-cpu-2x` web Machine with 4 GB RAM and one SQLite
writer. The volume starts at 20 GB and auto-extends to 50 GB. Do not scale the
web process horizontally while SQLite is the store.

## Backup and restore drill

The scheduler uses SQLite `VACUUM INTO` for an online, consistent nightly copy
in `/data/backups`. It keeps seven `daily-*` and four `weekly-*` databases and
runs `wal_checkpoint(TRUNCATE)`, `PRAGMA optimize`, and `ANALYZE` weekly.

For a restore drill, copy the newest backup to a separate temporary path, open
that copy with SQLite, run `PRAGMA integrity_check`, and start a disposable Muni
process with `MUNI_DB_PATH` pointing at the copy. Verify both Hall counts and one
Hall-isolated record query. A production restore requires stopping the sole web
writer, moving the damaged database and WAL aside, copying the verified backup
to `/data/muni.sqlite3`, and then starting exactly one web Machine. Never replace
the live database while its writer is running.
