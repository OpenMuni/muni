# Basemaps for self-hosted deployments

The map can serve a PMTiles package from `MUNI_TILES_PATH` or use an explicitly configured hosted provider. Set `MUNI_BASEMAP_MODE=pmtiles` when the local package is required. The `auto` mode uses a same-origin raster fallback when the PMTiles package is absent. Review the terms and capacity of any provider before using it for public traffic; the default fallback is useful for local development and evaluation.

OpenStreetMap data requires visible [attribution](https://www.openstreetmap.org/copyright). A Protomaps package and hosted map services have their own terms and notices. Do not send sustained production traffic directly to the volunteer `tile.openstreetmap.org` service.

Set `MUNI_MAP_STYLE`, `MUNI_MAPTILER_KEY`, or `MUNI_MAP_TILES` only after choosing your provider. Keep API keys on the server when the provider supports it. Test `/tiles/muni.pmtiles` with a byte-range request when using a local package.

Hall boundaries in `core/halls/<slug>.yml` are simplified map context. Review the source and license before replacing or publishing them. The Cambridge police collector uses the U.S. Census Geocoder; public Nominatim is disabled for recurring collection by default.
