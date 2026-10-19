const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture() {
  const context = {window: {}, URLSearchParams};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../public/js/muni.js'), 'utf8'), context);
  return {context, shell: context.window.muniShell({hall: 'cambridge', category: 'service_requests'})};
}

test('map methods receive the original instance rather than an Alpine proxy', () => {
  class MapInstance {
    #resizes = 0;
    resize() { this.#resizes++; }
    count() { return this.#resizes; }
  }
  const {context, shell} = fixture();
  const map = new MapInstance();
  const proxy = new Proxy(map, {});
  context.window.Alpine = {raw: value => value === proxy ? map : value};
  shell.map = proxy;
  shell.resizeMap();
  assert.equal(map.count(), 1);
});

test('record layers update after style readiness while base tiles are still loading', async () => {
  const {context, shell} = fixture();
  const data = {type: 'FeatureCollection', features: [{type: 'Feature', properties: {id: 'synthetic'}}]};
  context.fetch = async () => ({ok: true, json: async () => data});
  shell.map = {isStyleLoaded: () => false, once: () => assert.fail('Must not wait for another load event')};
  shell._mapStyleLoaded = true;
  shell.geoQueryParams = () => new URLSearchParams();
  shell.enrichGeojson = value => value;
  let installed;
  shell.installGeoLayer = value => { installed = value; };
  await shell.refreshGeo();
  assert.equal(installed, data);
  assert.equal(shell.geoFeatureCount, 1);
});

test('pending style data is not applied after the selected category changes', async () => {
  const {context, shell} = fixture();
  context.fetch = async () => ({ok: true, json: async () => ({features: []})});
  let onStyle;
  shell.map = {isStyleLoaded: () => false, once: (event, callback) => {
    assert.equal(event, 'style.load');
    onStyle = callback;
  }};
  shell.geoQueryParams = () => new URLSearchParams();
  shell.enrichGeojson = value => value;
  shell.installGeoLayer = () => assert.fail('Stale category data must not render');
  await shell.refreshGeo();
  shell.category = 'safety';
  onStyle();
});

test('retry resets style readiness and restores data on the new style event', () => {
  const {shell} = fixture();
  let onStyle;
  let refreshed = 0;
  shell._mapStyleLoaded = true;
  shell.map = {
    once: (event, callback) => { assert.equal(event, 'style.load'); onStyle = callback; },
    setStyle: () => { assert.equal(shell._mapStyleLoaded, false); onStyle(); }
  };
  shell.mapStyle = () => ({version: 8, sources: {}, layers: []});
  shell.installHallBoundary = () => {};
  shell.refreshGeo = () => { refreshed++; };
  shell.retryMap();
  assert.equal(shell._mapStyleLoaded, true);
  assert.equal(refreshed, 1);
});

test('cluster labels use the basemap font or the available Protomaps fallback', () => {
  for (const [styleLayers, expected] of [
    [[], ['Noto Sans Regular']],
    [[{layout: {'text-font': ['get', 'font']}}], ['Noto Sans Regular']],
    [[{layout: {'text-font': ['Roboto Regular']}}], ['Roboto Regular']]
  ]) {
    const {shell} = fixture();
    const layers = [];
    shell._mapStyleLoaded = true;
    shell.map = {
      getStyle: () => ({layers: styleLayers}), getSource: () => null, getLayer: () => null,
      addSource: () => {}, addLayer: layer => layers.push(layer), on: () => {}
    };
    shell.useCluster = () => true;
    shell.installGeoLayer({type: 'FeatureCollection', features: []});
    const label = layers.find(layer => layer.id === 'records-cluster-count');
    assert.ok(label, 'A cluster label layer must be installed');
    assert.deepEqual(Array.from(label.layout['text-font']), expected);
  }
});

test('311 uses individual signals and scopes the list to map bounds', () => {
  const {shell} = fixture();
  shell.map = {getBounds: () => ({getWest: () => -71.2, getSouth: () => 42.3,
    getEast: () => -71.0, getNorth: () => 42.5})};
  assert.equal(shell.useCluster({features: Array(10000)}), false);
  assert.equal(shell.queryParams().get('map_view'), '1');
  assert.equal(shell.queryParams().get('bbox'), '-71.2,42.3,-71,42.5');
  assert.equal(shell.geoQueryParams().get('bbox'), '-71.2,42.3,-71,42.5');
  const colors = shell.mapPointColor();
  assert.deepEqual(Array.from(colors).filter(value => typeof value === 'string' &&
    ['acknowledged', 'open', 'no_recent_update', 'other_active'].includes(value)),
  ['acknowledged', 'open', 'no_recent_update', 'other_active']);
  shell.listScope = 'history';
  assert.equal(shell.queryParams().get('history_view'), '1');
  assert.equal(shell.queryParams().has('map_view'), false);
});

test('overlapping 311 dots offer each request for selection', async () => {
  const {shell} = fixture();
  const first = {properties: {hall: 'cambridge', external_id: '1', case_type: 'Pothole'}};
  const second = {properties: {hall: 'cambridge', external_id: '2', case_type: 'Street light'}};
  shell.map = {queryRenderedFeatures: () => [first, second]};
  await shell.onMapPointClick({point: {x: 20, y: 20}, features: [first]});
  assert.deepEqual(Array.from(shell.nearbyRequests, f => f.properties.external_id), ['1', '2']);
});

test('311 history loads older rows without changing the map scope', async () => {
  const {context, shell} = fixture();
  shell.listScope = 'history';
  shell.filters = {time_range: 'all'};
  shell.historyHasMore = true;
  shell.rows = [{external_id: 'first'}];
  let requested;
  context.fetch = async url => {
    requested = url;
    return {ok: true, json: async () => [{external_id: 'older'}]};
  };
  await shell.loadMoreHistory();
  assert.match(requested, /history_view=1/);
  assert.match(requested, /offset=1/);
  assert.deepEqual(Array.from(shell.rows, row => row.external_id), ['first', 'older']);
  assert.equal(shell.historyHasMore, false);
});
