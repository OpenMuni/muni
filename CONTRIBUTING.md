# Contributing to Muni

Muni should be useful to the people described by its data. You can contribute
without writing Ruby: report a confusing chart, a missing source link, a stale
record, an accessibility problem, or a place where the interface hides an
important limitation. Please include the page URL, municipality, source record
link when available, and what you expected to understand.

## Before you start

- Search existing issues and pull requests. For a larger change or a new data
  source, open an issue first so we can agree on its public value and scope.
- Keep personal information out of issues, screenshots, test fixtures, and pull
  requests. A public record can still contain sensitive details. Link to the
  official record when possible instead of copying its contents.
- Report a vulnerability privately using [SECURITY.md](SECURITY.md), not an
  issue.
- Follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Local development

Use Ruby 3.3.6 and SQLite. From a clean clone:

```sh
./setup
export PATH="$PWD/.muni/bin:$PATH"
bin/test-all
bin/lint --cache false
./dev
```

The first `./dev` run collects public data and can take several minutes. Use
`./dev --no-collect` to reuse an existing local database. The web app and collectors do not require production accounts or credentials.
Connected identity and report-submission features are outside this source release.
See [README.md](README.md) for the repository layout and commands.

## Pull requests

Keep each pull request focused. Explain the user problem, the source or
methodology behind any data change, and how you checked the result. Include a
screenshot for a visible change when it clarifies the review. Add or update
tests for behavior changes that could regress. Do not include generated
databases, raw publisher downloads, credentials, report photos, or production
logs. Maintainers review for accuracy, privacy, accessibility, and fit with the
project's public purpose. They may ask for revisions before merging.

For a new data source, identify its official publisher, stable URL, update
cadence, terms of use, record identifiers, geographic coverage, likely privacy
issues, and how Muni will show provenance and gaps. Sources should be
repeatable and respectful of publisher rate limits. See
[docs/DATA_AND_ATTRIBUTION.md](docs/DATA_AND_ATTRIBUTION.md) and the existing
source criteria in [docs/CAMBRIDGE_BASELINE.md](docs/CAMBRIDGE_BASELINE.md).

Contributions to Muni's original code are submitted under the project's MIT
license. Identify any third-party code or assets you add and preserve their
required notices. The Muni name and logo are not a grant of endorsement for
independent deployments.
