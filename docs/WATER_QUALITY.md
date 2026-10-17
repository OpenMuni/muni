# Charles River data system

Charles River is a standalone region at `/water/charles`, backed by one Lower Charles evidence store and eight shared collection jobs. Enable with `MUNI_WATER_ENABLED=1`; the feature is off by default. Cambridge and Boston link to the same region. Legacy `/water?hall=cambridge` and `/water?hall=boston` links redirect while preserving filters. The region does not inherit a municipal cookie, register another Hall, or duplicate collectors. Optional water-source failures do not fail application liveness or municipal readiness.

This document describes the implemented contracts. Deployment details, data stores, and source freshness belong to each operator.

## Local operation and presentation rollback

```sh
MUNI_WATER_ENABLED=1 bundle exec muni data migrate
MUNI_WATER_ENABLED=1 bundle exec muni beats seed --waterbody=charles --json
MUNI_WATER_ENABLED=1 bundle exec muni beats serve
MUNI_WATER_ENABLED=1 bundle exec muni serve --bind=127.0.0.1 --port=4567
bundle exec muni water status --json
bundle exec muni water metrics --json
bundle exec muni water review --json
bundle exec muni water review EVIDENCE_ID --json
bundle exec muni water reconcile SOURCE --json
bundle exec muni water reconcile --normalize --json
bundle exec muni water reconcile SOURCE --normalize --json
```

Set `MUNI_DB_PATH=/absolute/path/preview.sqlite3` on every command to isolate a preview. `SOURCE` accepts a catalog suffix or its `water/charles/` slug. `water status` reports collection and calculation health; `water metrics` uses the same eligibility and local-reading presentation as the web API. `water review [ID]` is a read-only unresolved-evidence queue or retained evidence inspection, not an approval command. `reconcile SOURCE` requests source reconciliation; USGS history remains divided into bounded windows. `--normalize` reinterprets retained publications without making a publisher check or advancing successful-check timestamps. Raw source evidence and prior revisions remain retained.

`./dev` seeds shared water jobs after municipal seeds when enabled. A source can be checked with `muni beats run water/charles/epa_buoy --json`. The web preview alone does not start a collector scheduler; run `beats serve` against the same database. Migrations and normalization are repeatable.

`MUNI_WATER_PRESENTATION_ENABLED=0` provides a presentation maintenance/rollback switch. Collectors continue and `/api/water/charles/coverage` remains available; other water data APIs return a maintenance response and the river page shows maintenance. It does not roll back or delete evidence. `MUNI_WATER_ENABLED=0` disables the feature and its registered jobs instead.

`MUNI_WATER_PROCESSING_ENABLED=0` pauses scheduled water collection and water calculation maintenance while municipal collectors continue. It defaults to `1` and does not disable water routes or coverage. For a staged reconciliation, set both processing and presentation to `0`, run explicit `water reconcile` commands against the chosen database, verify the results, then restore both flags to `1`. Explicit `Ingestor`/`Reconciler` operations and the `water reconcile` command remain available during this pause; `beats run` respects the processing pause. Retained evidence, source checkpoints and queued calculations are preserved.

## Source calendars and import boundaries

| Job suffix | Normal check schedule | Import/reconciliation | Observation cadence / allowance |
|---|---|---|---|
| `crwa_predictions` | Hourly at UTC `:10` | Latest 24 hours, four reaches, publisher model version retained | Hourly during boating season / 4 hours |
| `crwa_boathouses` | UTC `:00`, `:15`, `:30`, `:45` | Publisher boathouse override states | Event-driven / 1 hour for publisher-state checks |
| `wqp` | Friday 04:00 America/New_York | Selected CRWA station metadata and E. coli results; 400-day overlap, full monthly reconciliation and after selection/normalization changes | Irregular historical samples |
| `crwa_laboratory` | Daily 05:00 America/New_York | Small edition check; full pages only for edition/selection/normalization changes, monthly reconciliation, or missing edition metadata | Irregular historical samples |
| `epa_buoy` | UTC `:10` and `:40` | Current deployment CSV; fingerprint each timestamp row and expand only changed rows, including old corrections | 15-minute readings / 2 hours |
| `usgs` | Hourly at UTC `:50` | Waltham `USGS-01104500`, parameters 00060 and 00065; seven-day recent overlap and resumable current-year history | 15-minute readings / 2 hours |
| `cambridge_cso` | UTC `:00`, `:15`, `:30`, `:45` | Published Charles River discharge notices and supported corrections | Event archive; check health separate from event date |
| `mwra_cso` | UTC `:00`, `:15`, `:30`, `:45` | CSV records whose receiving-water context includes the Charles | Event archive |

Schedules are fixed calendar occurrences, not delays measured from completion. Friday/daily local schedules follow New York daylight-saving time; frequent schedules use UTC. A first run without scheduling history is immediately due. Missed occurrences coalesce into one check. `MUNI_WATER_<UPPERCASE_JOB_SUFFIX>_INTERVAL` selects an explicit completion-relative override in seconds, minimum 60. The municipal scheduler keeps its existing interval behavior.

Observation cadence remains independent of collection frequency: slower checking neither resamples retained readings nor lowers coverage expectations. Boathouse and notice schedules express detection latency, not a regular publisher release promise. Authoritative URLs, selections, cadence policy and location associations are in `core/lib/muni/water/catalog.rb`. Optional `USGS_API_KEY` is sent server-side only to the USGS origin, never to browsers or retained request URLs.

USGS initially publishes a complete recent seven-day window for both parameters. Later jobs work backward through complete windows of at most seven days, committing each window independently. The checkpoint reports `backfill_pending`, the current `collection_window`, and completed reconciliation month; a successful initial check does not mean the year is fully imported. Continuations are due after five seconds, while overdue routine checks take priority. Hourly recent refreshes interrupt historical progress when due. ArcGIS and USGS yield between pages to other due jobs through the existing serial scheduler; no worker pool or new service is required. The USGS month advances only when its historical cursor reaches the year's start.

### Shared transport, retries and atomic publication

`Muni::Helpers::Http` supplies the shared response envelope: status, headers, raw body, resolved URL and actual receipt time. `Muni::Clients::Arcgis` owns protocol pagination. `Water::Client` adds conditional requests and a resumable response journal. Water uses one HTTP attempt per request, a 10-second connection timeout and 30-second response timeout. Typed transport errors distinguish transient failures and carry `Retry-After`.

Transient collection failures schedule retries after 15 minutes, 1 hour, 4 hours, then 1 day. The earlier retry or next normal occurrence wins, unless `Retry-After` requires a later request. Permanent/schema failures wait for the next normal occurrence. Timing and failure counts persist in `water_schedule_state`; success resets the count. Source leases and source-specific process locks prevent overlapping scheduled/manual imports. A process crash releases its file lock; expiring leases permit recovery.

An expired lease cannot displace a process still holding the source lock. Busy scheduled checks defer for 30 seconds without recording a collection failure. The scheduler retains `last_due_at`, `last_started_at` and `next_run_at`; coverage exposes the next check and the previous start delay independently of measurement freshness. Publisher edition intervals are separately observed from explicit publisher timestamps, or clearly labeled first-observed body changes when no publisher clock is supplied. Neither is the configured collection schedule or a promised release frequency; 304s and older backfill editions do not create new publication intervals.

New collection runs retain scheduling facts in `water_runs.metadata.scheduling`: actual run start, scheduled due time, delay, invocation/trigger, routine/backfill/reconciliation work kind, and the calendar/retry policy snapshot. Successful publication preserves these facts; failed attempts retain them too. The next due decision and its originating run ID are retained atomically with lease completion. Direct imports and manual beat runs are identified separately; deferred lease attempts do not invent a started run. Older runs remain unmeasured.

Coverage's per-source `start_timing_24h` reports the nearest-rank p95 and maximum start delay, eligible/failed start counts, starts over 60 seconds, excluded runs and legacy unmeasured runs. Routine scheduled calendar/retry/resumed checks enter the overall percentile; startup, manual, reconciliation and backfill runs do not. `timing_groups` separates successful calendar/resumed checks, retries and failed starts; a failed retry belongs to both latter groups. These categories do not identify the cause of a delay. USGS retains its planned work kind and routine deadline, then records the actual completed window kind; a continuation that executes routine work is measured against the routine deadline without rewriting its original invocation due time. `recorded_since` and `covers_full_window` describe retained instrumentation history, not uninterrupted uptime. A timing gate needs a complete window, eligible starts and the separately reported outstanding expectations; an empty percentile is not a pass. `expectations` reports recorded next-check decisions that never started, including the oldest outstanding decision before the window. Additional calendar slots skipped during an outage are not reconstructed. The report reads indexed run timestamps and small scheduling metadata, never archived response bodies or measurement history.

Successful pages are staged in `water_pending_pages` and remain unpublished. Transient failures can resume the same logical snapshot for up to 24 hours; invalid snapshots discard staged pages. A 304 preserves prior validators, source context, body receipt time and evidence, while recording a successful check. A successful download is not a new measurement.

ArcGIS checks the layer's data/edit marker before and after pagination. Changed editions discard the unpublished pages and restart; continuous changes defer the import after two restarts. A failed previous edition cannot supply pages to a newer edition. Missing/invalid markers require a full fetch; they cannot prove that an unversioned publisher stayed unchanged. The edition/query/normalization signature and month advance only with a complete validated publication.

Parsing, normalization, semantic comparisons, compression and dirty-day planning happen outside the writer lock. A source batch publishes current evidence, immutable revisions, checkpoint, response references, run completion and a durable calculation job in one transaction using bounded set-based writes. A failed batch publishes none of those changes. USGS uses one such transaction per complete logical window; ArcGIS uses one for the validated complete archive. Older resumed responses cannot overwrite newer retained evidence. Absence from a rolling response is never treated as retraction.

Collection and calculation failures are separate. Published evidence remains available if a calculation fails. A separate process lock serializes calculation workers without holding the publication writer during computation. Before publishing summaries or shift findings, the worker checks whether that source acquired newer revisions after its input snapshot; if so, it discards the outdated calculation and retries current evidence. Unrelated source publications do not trigger this retry. Failed calculation jobs retry after 30 seconds, 2 minutes, 10 minutes, then hourly; abandoned running jobs can resume after process exit. The scheduler runs bounded calculation maintenance after due collectors. Coverage reports batch phases, calculation backlog and writer duration independently of collection success.

## Normalized evidence and shared selection

Normalization is versioned as `water-normalization-v1`; daily statistics use `water-daily-v2` and signals use `water-v2.0`. Additive evidence fields include `observed_date`, `time_precision`, `normalization_version`, and indexed `publication_group_id`. Publisher IDs, raw records, original values/units and immutable earlier versions are retained. A reinterpretation of unchanged publisher bytes is marked as normalization, not announced as a publisher correction.

Date-only samples retain their published calendar date with no fabricated observation instant. ArcGIS's mixed midnight encodings retain the nominal date. Explicit EPA EDT/EST labels determine instants; ambiguous unqualified Eastern times require review. Observed/valid time, publisher change time, body receipt time, normalization/publication time and successful-check time are distinct.

The shared eligibility policy supplies the web overview, metrics API, CLI, charts and calculations:

- Confirmed routine, QC/nonroutine and unknown-role laboratory samples remain distinct. A newer qualified unknown-role result may appear alongside the latest confirmed routine result, with its limitations stated.
- Exact repeated ArcGIS publications are grouped when their source attributes support the identity. All original publications and IDs remain inspectable. Similar WQP/ArcGIS results are unresolved cross-source candidates, not automatically one sample.
- Censored results retain their comparator, bound and unit. MPN and CFU are never converted or pooled. Unspecified analytical methods stay unspecified.
- Rejected/retracted/review records, QC samples, unusable numeric results and inappropriate biological estimates are excluded from calculations under explicit reasons. Negative biological estimates remain visible as source evidence, never silently changed to zero. Negative fluorescence remains qualified rather than treated as an organism count.

Records defaults in the UI to **Observations**, which groups supported repeated publications. **Source publications** exposes every retained publisher record, including QC and repeated representations. Record counts therefore do not claim independent sample counts. Raw source records and version history are available through evidence inspection.

## Storage, incremental calculations and recovery

All state uses the configured SQLite database and existing MuniStore writer coordination:

| Table | Purpose |
|---|---|
| `water_evidence`, `water_revisions` | Current normalized evidence and immutable source/normalization versions |
| `water_runs`, `water_checkpoints` | Permanent check history and successful publication boundaries |
| `water_batches` | Batch identity, signature, response digest manifest, phase timestamps and publication/calculation status |
| `water_calculation_jobs` | Durable dirty-day/revision work, attempts, retry time and worker claim |
| `water_daily_summaries`, `water_daily_summary_versions` | Current per-series/local-day statistics and immutable prior calculations, including coverage, fingerprints and exact retained input revisions |
| `water_signals`, `water_signal_versions` | Current interpretations and retained prior calculations |
| `water_schedule_state` | Calendar due time, failure count and source lease |
| `water_locations`, `water_associations` | Shared catalog and municipality context |
| `water_responses` | Compressed exact response bodies; ordinary diagnostics retained 30 days, supporting PDFs retained for verification |
| `water_pending_pages` | Unpublished resumable pages, reused for at most 24 hours |

Dirty days include both old and new selectors/dates when a correction moves a record. Publication atomically removes affected current summaries and sustained-shift findings while retaining their immutable calculation history. Only those summaries and affected shift windows are recalculated; a pending or failed calculation cannot leave an earlier finding presented as current. Complete-day charts reuse durable summaries; current/partially selected days and summaries awaiting materialization calculate the necessary boundary observations. Summary versions and current projections publish together in a transaction. One local day closes per maintenance tick, with a persisted guard preventing repeated midnight work and bounded catch-up after downtime. DST days expect 92 or 100 quarter-hour slots rather than 96.

Missing-observation calculations inspect corrected local days and the newly monitored tail, using indexed neighboring observations to preserve a long gap's identity. Monitoring starts when Muni begins checking, not at the earliest historical sample. Gaps filled by later publications retain their history; replaced deployments stop accruing expected intervals.

Only direct EPA sensors enter sustained-shift calculations. Each dirty day affects window endings through the following 30 days. A shift requires three complete local-day medians in the same direction, each beyond three robust standard deviations from the preceding 28 days. Robust SD is `1.4826 × MAD`; each qualifying day needs at least 80% coverage, all three recent days must qualify, and at least 21 baseline days are required. Zero dispersion or insufficient coverage suppresses classification. Source/location/unit/method/deployment series stay separate. Daily statistics retain exact input revision IDs and per-day cutoffs; signals retain those inputs for reconstruction. Corrections can change earlier classifications without losing prior history, including a return to a previously seen classification.

Collection interruptions use failed checks or checks overdue by two configured intervals. Publication-change signals compare retained raw evidence; normalization-only revisions are excluded. No automated signal establishes a pollution cause, sensor fault, swimming safety or a health threshold.

Municipal retention and Beat-log pruning do not remove permanent water evidence. Backfill adds observations but cannot reconstruct pre-monitoring revisions or check reliability. Existing SQLite backups include these tables. Before migration, keep an immutable release backup off the production volume and verify a detached restore using the existing backup/snapshot mechanisms. Run `muni data migrate` on the restored copy; never replace an open database file. Storage grows with observations and revisions; monitor database and backup sizes. Disabling presentation or collection does not delete evidence.

## Discharges and reviewed advisories

Discharge reconciliation requires publisher identity or a uniquely shared notice document. Matching date/outfall alone does not establish one event; ambiguous same-day notices remain in review and are excluded from countable events. Cambridge and MWRA publications remain separate. Retractions, event estimates, censored volumes, historical averages, rainfall/treatment context and original links remain retained; the UI has no river-wide discharge-volume total.

The supported Cambridge July 29, 2023 correction is applied only while its linked PDF bytes match the reviewed SHA-256. The corrected CAM005 retraction and omitted CAM017 publication retain document provenance. The PDF is conditionally rechecked even if the parent page returns 304. Changed bytes require review; request failures do not silently reuse an unverified interpretation.

Government advisories, BWSC and MassDEP remain explicit coverage gaps. CRWA overrides are program states; inactive retained reason text does not activate a warning. Reviewed government advisories can be imported separately:

```sh
MUNI_WATER_ENABLED=1 bundle exec muni water advisory /absolute/path/reviewed-advisory.json --json
```

Required fields are `id`, `issuer`, HTTP/S `source_url`, `scope` (`charles`, `reach-2` through `reach-5`, or known location ID), `reviewer` and `title`. Include `issued_at`/`expires_at` only when known. Reuse issuer/id for a correction. Expiry never creates an all clear; reviewed notices remain visible beside favorable predictions.

## Read-only API and human-readable views

All routes are under `/api/water/charles`, require `MUNI_WATER_ENABLED=1`, and use the presentation flag exception described above.

| Suffix | Response |
|---|---|
| empty | Latest local evidence, qualified sample/notice snapshots, advisories, locations and methodology |
| `/metrics` | Shared metric presentation, primary/qualified/routine readings and limitations |
| `/geojson` | Verified source geometry and separately listed unlocated places |
| `/series` | Retained records or explicit `aggregation=hour` / `aggregation=day` sensor/gauge medians |
| `/trends` | Compatible measurement summaries; `presentation=observations` gives individual lab/model observations; legacy publication-count/check modes remain supported |
| `/records`, `/events` | Paginated records or discharge publications |
| `/signals` | Current signals; `versions=1&key=…` retrieves retained versions |
| `/signals/:id/evidence` | Exact retained input revisions; older signals retain the cutoff reconstruction fallback |
| `/coverage` | Independent collection, freshness, history and calculation status |
| `/evidence/:id` | Current normalized record and immutable versions including original payloads |
| `/export.csv` | Paginated normalized records, dates, qualifications, grouping and provenance |

Filters include `location`, `reach`, `source` (full slug), `parameter`, `unit`, `method`, `kind`/`kinds`, `from` and `to`. ISO dates use local calendar days; `to` is exclusive. The UI's custom range is inclusive and translates that boundary. `presentation=observations` groups supported duplicates; `presentation=publications` preserves all publications and is the backward-compatible records API default. Location, parameter and unit remain explicit for measurement trend requests; units/methods/deployments never share an aggregate.

Pages default to 500 records and allow up to 5000. Offset pagination remains compatible. `cursor=start` starts an immutable revision-boundary traversal; later requests use `next_cursor` with the same filters. CSV exports use this snapshot mode by default and return `X-Next-Cursor` and `X-Revision-Cutoff` alongside legacy count/offset headers. Concurrent publications cannot shift rows between cursor pages. Exported publisher text escapes spreadsheet formula prefixes. The page's CSV action follows the cursor until completion.

The river overview is the default, organized around local evidence about contact conditions, aquatic measurements and flow. It makes no river-wide measurement or composite safety score. Metrics show the location, observation date, unit, source and qualifications. Typical sensor history starts at 30 days; laboratory history uses 365 days unless the user chooses another period. Laboratory charts show individual qualified results and bounds; hourly model output uses a dashed line. EPA concentration estimates remain separate from direct fluorescence, pH is shown as a line, and USGS stays upstream context. Discharge charts count countable publications separately by publisher, without converting them into a river-wide total. Missing intervals break lines rather than being interpolated.

Metrics, Map, Records and Datasets share URL filters and the river region selector. Datasets separates checks, publisher changes, observation history and retained publication counts. Records offers Observations/Source publications, source/type filters, evidence inspection and exports. A newer unknown-role laboratory result does not erase an older confirmed routine result. Refresh reads stored Muni data; scheduled collectors contact publishers.

The map uses a reviewed, generalized CRWA waterbody outline and source-supplied locations. It is not a condition boundary. Unverified locations remain in the list without a pin; reach associations provide context rather than whole-reach measurements. Desktop/mobile map selection, keyboard controls and accessible chart tables follow the existing municipal patterns.

## Verification workflow

```sh
MUNI_DB_PATH=/tmp/muni-water-test.sqlite3 MUNI_LOG_LEVEL=error MUNI_MAINTENANCE_ENABLED=0 \
  bundle exec rspec --pattern '{core,www}/spec/water*_spec.rb'
MUNI_DB_PATH=/tmp/muni-all-test.sqlite3 MUNI_LOG_LEVEL=error MUNI_MAINTENANCE_ENABLED=0 bundle exec rspec
node --test www/spec/js/*test.cjs
bundle exec rubocop --no-server --cache false
```

Set an isolated startup database even though individual examples isolate their own stores: the spec helper boots the application before per-example isolation. Synthetic publisher-shaped fixtures are under `spec/fixtures/water`; unit tests do not need upstream access. Tests cover fixed calendars and DST, typed retries, leases/cooperative execution, 304 preservation, incomplete/stale edition rejection, bounded backfill, correction identity, normalization/eligibility, exact input reconstruction, cursor stability, calculation recovery, backup restore and presentation maintenance. Supplement with a detached real-data preview and browser checks. Release acceptance and measured performance must be recorded in the release evidence, not inferred from passing fixtures.

Notifications, independent rainfall collection, ECHO integration, new prediction models and native iOS screens remain outside this scope.
