# Public release gate

This checklist applies to source releases of `OpenMuni/muni`. Publishing source does not publish the operated service's database, uploads, credentials, or deployment runbooks, and does not deploy the code.

## Decisions required from the project owner

1. The project owner confirmed personal ownership of the original Muni code and documentation and requested the MIT copyright notice identify Charles Magnarelli. Preserve third-party notices and verify any future contributions before distributing them under the MIT license.
2. The project owner confirmed control of the Muni.fyi name and visual identity and approved their use in the public source. The code license does not grant independent deployments an endorsement or trademark license. The iOS app and its logo/image assets remain withheld until their specific provenance and redistribution terms are documented.
3. Before restoring any third-party visual assets, record each source, version, license, required notice, and attribution. The current web SVGs are original placeholder badges.
4. If the Boston municipal boundary or CRWA river geometry is wanted in the repository, verify the license for each specific dataset and record attribution. Both are withheld. The water parser fixtures and correction PDF are synthetic; do not replace them with publisher excerpts without explicit redistribution rights and privacy review.
5. Confirm any additional maintainers and how Muni.fyi should describe its stewardship. A separate foundation is not required for this source release. The security and conduct contact is `hello@muni.fyi`.

## Final public-release steps

1. Record the owner decisions above and resolve any resulting code, license, attribution, or branding changes in reviewed commits.
2. Recheck every tracked file, the clean repository history, the live GitHub file list, and CI artifacts for secrets, private records, generated files, and unlicensed content. Rotate any credential found exposed.
3. Run `./setup`, `bin/test-all`, `bin/lint --cache false`, `python3 bin/test-http-security.py`, and `npm ci --ignore-scripts && npm test` from a fresh checkout without production credentials. Require passing CI jobs for tests, current dependency audits, full-history secret scanning, and the container build/security scan.
4. Verify branch protection, dependency and secret scanning, private vulnerability reporting, and repository access. Some GitHub plans do not enforce protection for private repositories; verify enforcement as part of the public transition. Keep production secrets and deployment runbooks outside this repository.
5. After the owner authorizes publication and all checks pass, commit the reviewed source, merge its pull request, and require the merged `main` CI run to pass before changing `OpenMuni/muni` visibility to public. Immediately verify public contents, required reviews/status checks, secret scanning/push protection, and private vulnerability reporting. Website changes and announcements are separate actions.

The live Muni.fyi service, database, uploads, and reporting workflow require their own privacy and operations review before any related publication.
