# Public release gate

This private source snapshot is prepared for review. It is not authorization to change repository visibility, publish data, or deploy the service.

## Decisions required from the project owner

1. The project owner confirmed personal ownership of the original Muni code and documentation and requested the MIT copyright notice identify Charles Magnarelli. Preserve third-party notices and verify any future contributions before distributing them under the MIT license.
2. The project owner confirmed control of the Muni.fyi name and visual identity and approved their use in the public source. The code license does not grant independent deployments an endorsement or trademark license. The iOS app and its logo/image assets remain withheld until their specific provenance and redistribution terms are documented.
3. Before restoring any third-party visual assets, record each source, version, license, required notice, and attribution. The current web SVGs are original placeholder badges.
4. If the Boston municipal boundary or CRWA river geometry is wanted in the repository, verify the license for each specific dataset and record attribution. Both are withheld. The water parser fixtures and correction PDF are synthetic; do not replace them with publisher excerpts without explicit redistribution rights and privacy review.
5. Confirm any additional maintainers and how Muni.fyi should describe its stewardship. A separate foundation is not required for this source release. The security and conduct contact is `hello@muni.fyi`.

## Final public-release steps

1. Record the owner decisions above and resolve any resulting code, license, attribution, or branding changes in reviewed commits.
2. Recheck every tracked file, the clean repository history, the live GitHub file list, and CI artifacts for secrets, private records, generated files, and unlicensed content. Rotate any credential found exposed.
3. Run `./setup`, `bin/test-all`, `bin/lint --cache false`, and `/healthz` from a fresh checkout without production credentials. Confirm the GitHub read-only CI run passes.
4. Verify branch protection, dependency and secret scanning, private vulnerability reporting, and repository access. GitHub currently marks the `main` branch rule as unenforced while this private repository is on a free personal account. Verify enforcement after making the repository public, or move to an account and plan that supports private branch protection before relying on the rule while private. Keep production secrets and deployment runbooks outside this repository.
5. Only after an explicit owner decision to publish, change `charliemags/muni` visibility to public. Inspect its public file list and notices. Then update the project website and announce contributor channels separately.

The live Muni.fyi service, database, uploads, and reporting workflow require their own privacy and operations review before any related publication.
