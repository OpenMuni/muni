# Data, maps, and third-party attribution

Muni's [MIT license](../LICENSE) applies to original software and
documentation in this repository. It does not change the terms of data or
assets supplied by others. A public source is not automatically free of
privacy, accuracy, attribution, or redistribution limits.

## Data and privacy

Muni reads municipal and regional sources, then creates a local SQLite store.
The repository does not distribute the live store, full raw response archive,
backups, submitted reports, or uploaded photos. Offline tests use synthetic publisher-shaped fixtures. The repository omits CRWA-derived river geometry, the copied Cambridge correction PDF, and the simplified Boston boundary pending dataset-specific redistribution review. Local and production copies can contain names,
addresses, precise locations, contact details, or other
sensitive material even when a source is public. Keep them out of commits,
issues, fixtures, and screenshots. Link to a publisher record instead of
reposting sensitive content.

Sources should identify their publisher and original URL in the application.
Before adding a source or publishing a dataset extract, check the terms on the
specific publisher page and record the applicable license or restrictions.
Cambridge's Open Data program marks datasets released under the Open Data
Commons Public Domain Dedication and License (PDDL). Boston has described its
Analyze Boston data as PDDL, but an older City data-license page has different
terms; verify the terms on each dataset rather than assuming one blanket grant.
Other feeds, including Open311, agency pages, EPA, USGS, CRWA, and MWRA, need
their own source-level review before a snapshot is redistributed.

- [Cambridge Open Data licensing announcement](https://www.cambridgema.gov/departments/opendata/news/2024/02/cambridgeadoptspddllicenseforopendataamilestoneforenhancedusabilityandpublictrust)
- [Analyze Boston public-domain announcement](https://www.boston.gov/ar/news/analyze-boston-puts-bostons-data-public-domain)
- [City of Boston data-license page](https://www.boston.gov/government/cabinets/innovation-and-technology/city-boston-data-license-agreement)

Data can be delayed, incomplete, revised, or geographically approximate. Show
the source, observation date, update date, and methodological limits wherever
they affect interpretation. A Muni display is not an official city record or
an emergency or health advisory.

## Maps and assets

- MapLibre GL JS 6.15.0 distribution modules and CSS are served locally from
  `www/public/vendor/maplibre-gl/` so module workers share the application's
  origin. They are copied unmodified from the locked npm package, retain its
  BSD-3-Clause `LICENSE.txt`, and are checked against that package in CI.

- OpenStreetMap data is under the Open Database License (ODbL). Public maps
  using it must provide [OpenStreetMap attribution](https://www.openstreetmap.org/copyright).
  See [production basemap guidance](BASEMAPS.md) for Muni's rendering options.
- Protomaps basemap packages and any hosted map provider have their own terms.
  Keep the attribution required by the actual deployed provider.
- The bundled interface SVGs are original, simple placeholder badges created for this source snapshot and covered by the repository MIT license. They replace earlier icons whose provenance was unclear. Before restoring any third-party icons, record their source and license and preserve required notices.
- The iOS app and Muni logo image assets are withheld from this snapshot pending ownership and redistribution review.
- The Muni name and visual identity identify the operated service; the MIT code license does not grant endorsement of independent deployments.
