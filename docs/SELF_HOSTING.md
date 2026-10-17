# Self-hosting Muni

Start with a local installation before deploying a public instance. Use Ruby
3.3.6 and SQLite:

```sh
./setup
./dev --no-collect
```

The local site defaults to `http://127.0.0.1:4567`; `/healthz` checks the web
process. Remove `--no-collect` to seed the configured public sources. Collection
uses live publisher APIs and can take several minutes or encounter rate limits.
The site does not require production credentials. Optional meeting summaries
use an Anthropic API key supplied by the operator.

For a hosted instance, provide a persistent writable volume for SQLite,
backups, and any generated tiles. Run one writer against that volume;
the scheduler and web process share the store. Arrange external backups and a
restore drill. Configure your own domain, TLS, monitoring, secrets, and map
provider, and verify the attribution and terms of every source you enable.
The included `Dockerfile` and `bin/start` show the process layout. Bring your own deployment configuration, app name, domain, storage, and credentials.

Connected sign-in, resident report submission, and the operator view are not
part of this source release. Restore them only after an independent identity
system and a privacy review are in place. See [data and attribution](DATA_AND_ATTRIBUTION.md)
and the [contribution guide](../CONTRIBUTING.md).
