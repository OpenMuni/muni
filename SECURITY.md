# Security policy

Please report a suspected vulnerability privately through GitHub's **Report a
vulnerability** feature when it is available for this repository, or email
[hello@muni.fyi](mailto:hello@muni.fyi) with `Muni security` in the subject.
Include a way to reproduce the issue and its likely impact. Do not post exploit
details, credentials, private report content, or personal information in a
public issue.

Maintainers will review reports affecting the current `main` branch and the
operated Muni.fyi service, coordinate a fix, and discuss disclosure with the
reporter. The public data feeds are maintained by their publishers; report an
upstream data problem to the publisher as well when appropriate. For an
ordinary data correction or product bug, use an issue without copying private
information.

## Maintainer checks

CI tests the application and real HTTP worker availability, audits Ruby, Python,
and browser dependency locks, scans the full Git history for secrets, and builds
and scans the container for fixable high/critical vulnerabilities. The same
checks run weekly. Container findings without an upstream fix still need review;
the automated threshold is not a claim that an image has no vulnerabilities.

Keep `.env` files, databases, uploads, Terraform state, and production runbooks
outside commits and container build contexts. Never copy production data into
test fixtures. Detailed operational errors stay in private storage; public
responses use generic failure messages, and logs redact credential fields and
configured secret values.

The optional event endpoints return finite batches with a 15-second EventSource
reconnect interval. They do not hold request workers open while waiting for data.
Self-hosted deployments should still enforce request limits at their trusted edge.

Browser libraries are pinned in `package.json`; CDN versions also appear in the
layout template. MapLibre's modules are served locally with their license.
After updating them, regenerate `package-lock.json`, install with `npm ci --ignore-scripts`,
refresh CDN integrity hashes with `node bin/check-browser-dependencies.cjs --write`,
run `npm test` and `npm audit`,
and check the pages and maps in a browser. Python dependencies are locked with
hashes in `mcp/requirements.lock`; regenerate with `pip-compile --generate-hashes
--strip-extras --output-file mcp/requirements.lock mcp/requirements.txt` on Python 3.11
and audit with `pip-audit -r mcp/requirements.lock --require-hashes`.
