# Analytics

Muni analytics are lightweight, cached civic estimates computed from local
SQLite records. They are advisory summaries of historical official data, not
official city forecasts.

## Refresh

The Cambridge analytics beat runs daily:

```sh
bundle exec muni beats run cambridge/analytics --json
```

You can recompute manually:

```sh
bundle exec muni analytics run --hall=cambridge --json
```

Read the cached snapshot:

```sh
bundle exec muni analytics show --hall=cambridge --json
```

Analytics are stored in `analytics_results` with one JSON payload per hall,
kind, and key. Web requests read this cache only; they do not train models.

## Models

### 311 Resolution Time

The 311 model trains on service requests with valid `opened_at` and `closed_at`
timestamps. It uses empirical duration buckets with this backoff order:

1. case type, department, neighborhood, weekday
2. case type, department, neighborhood
3. case type, department
4. case type
5. department
6. citywide

Predictions return the bucket median and a 10th to 90th percentile range.
Description keywords can nudge the prediction only when a keyword has enough
historical closed-case samples; otherwise matched words are reported only as
context.

### Permit Processing Time

The permit model trains on issued permits with valid `applied_at` and
`issued_at` timestamps. It uses permit type, property use, and declared
valuation buckets. Neighborhood is intentionally excluded because the current
permit schema does not include it.

### Crash Risk

Crash risk groups records by rounded coordinates, falling back to normalized
location text when coordinates are missing. Scores are weighted by recency and
severity factors: injury, fatality, cyclist involvement, and pedestrian
involvement. Scores are normalized to 0-100 within the cached result.

### 311 Volume Anomalies

Anomaly detection compares the latest source-covered 7-day case-type volume to
historical weekly baselines. Same-month seasonal baselines are used when enough
history exists; otherwise the detector falls back to rolling prior weeks. An
alert requires a minimum current count, a volume ratio spike, and a robust
z-score spike.

## API

```text
GET /api/predictions/service_requests?hall=cambridge&case_type=Pothole&department=DPW
GET /api/predictions/permits?hall=cambridge&permit_type=Building&declared_valuation=50000
GET /api/predictions/crash_risks?hall=cambridge&limit=10
GET /api/predictions/service_request_anomalies?hall=cambridge&limit=10
```

`GET /api/dashboard?hall=cambridge` includes an `analytics` object with cached
summary payloads for dashboard widgets. If analytics have not run yet, payloads
return `status: "warming"`.
