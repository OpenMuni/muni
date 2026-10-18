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

The 2026-10-18 release image uses Debian Trixie and removes compiler/development
packages after installing gems. Its broader scan, including unfixed findings,
reported no critical vulnerabilities and ten distinct high-severity Debian
advisories with no fixed distribution package yet (47 package-level matches):

- util-linux: CVE-2026-76642, CVE-2026-78408, CVE-2026-78409, CVE-2026-78410.
- curl: CVE-2026-12064, CVE-2026-8458.
- acl: CVE-2026-54369; systemd: CVE-2026-16742.
- ncurses: CVE-2025-69720; Perl Archive::Tar: CVE-2026-9538.

These are scanner version matches, not demonstrated application exploits.
The mount/cgroup, home-management, archive, and terminal operations described
by these advisories are not part of Muni's web request handling. The packaged
curl utility is used by the optional HTTP uptime script, not the Ruby data
clients. Review these findings against each deployment's configuration, avoid
privileged containers, and rebuild as distribution fixes become available.
Source publication does not deploy this image or certify an existing service.

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
