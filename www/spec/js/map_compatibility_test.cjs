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
