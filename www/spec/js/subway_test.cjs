const assert = require('node:assert/strict');
const {fresh, decodePolyline, routeFeatures, muniSubway} = require('../../public/js/subway.js');

const encoded = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';
assert.deepEqual(decodePolyline(encoded), [[-120.2,38.5],[-120.95,40.7],[-126.453,43.252]]);
for (const invalid of [null, '', '_', '~~~~~~~', '??']) assert.throws(() => decodePolyline(invalid), /Invalid route geometry/);
const branches = routeFeatures([
  {route:'Red', polyline:encoded}, {route:'Red', polyline:'??AA'},
  {route:'Green-E', polyline:'??BB'}, {route:'CR-Fitchburg', polyline:encoded}
]);
assert.equal(branches.features.length, 3, 'each subway branch remains a separate path');
assert.equal(branches.features[0].properties.color, '#da291c');
assert.equal(branches.features[2].properties.color, '#00843d');
assert.equal(branches.features[0].geometry.coordinates.length, 3, 'never join the end of one branch to the next');

const now = Date.now();
const stamp = offset => new Date(now + offset).toISOString();
assert.equal(fresh(stamp(-1000), now), true);
assert.equal(fresh(stamp(-60000), now), false);
assert.equal(fresh(stamp(60000), now), false);
assert.equal(fresh('invalid', now), false);

global.localStorage = {getItem:()=>'place-harsq', setItem:()=>{}};
const app = muniSubway();
assert.equal(app.view, 'arrivals', 'station arrivals is the default view');
app.selectedStation = 'place-harsq';
app.selectView('alerts');
assert.equal(app.view, 'alerts');
assert.equal(app.listOpen, true, 'alerts open the mobile sidebar');
app.selectView('arrivals');
assert.equal(app.selectedStation, 'place-harsq', 'view switching preserves station selection');
app.vehicles = [
  {id:'red', route:'Red', updated_at:stamp(-1000)},
  {id:'blue', route:'Blue', updated_at:stamp(-1000)},
  {id:'stale', route:'Orange', updated_at:stamp(-60000)}
];
assert.deepEqual(app.visibleVehicles().map(v => v.id), ['red', 'blue'], 'show fresh vehicles across all routes');

async function testArrivals() {
  const paths = [];
  app.selectedStation = 'place-harsq';
  app.get = async path => {
    paths.push(path);
    return {fetched_at:stamp(-1000), data:[
      {id:'later', route:'Red', arrival_time:stamp(120000)},
      {id:'first', route:'Red', arrival_time:stamp(60000)},
      {id:'cancelled', arrival_time:stamp(1000), schedule_relationship:'CANCELLED'},
      {id:'old', arrival_time:stamp(-120000)}
    ]};
  };
  await app.loadPredictions();
  assert.deepEqual(app.predictions.map(p => p.id), ['first', 'later']);
  assert.deepEqual(paths, ['/predictions/place-harsq']);

  app.selectView('alerts');
  app.listOpen = false;
  app.selectStation();
  assert.equal(app.listOpen, true, 'station selection opens arrivals on mobile');
  assert.equal(app.view, 'arrivals', 'selecting a map station returns from alerts to arrivals');
  app.selectedStation = '';
  await app.loadPredictions();
  assert.deepEqual(app.predictions, [], 'clearing station clears arrivals');
}

async function testMap() {
  const elements = [];
  global.document = {createElement:() => ({
    style:{setProperty() {}}, attributes:{}, children:[],
    get classList() { return {toggle:(name, enabled) => {
      const names = new Set(this.className.split(' '));
      enabled ? names.add(name) : names.delete(name); this.className = [...names].join(' ');
    }}; },
    setAttribute(key, value) { this.attributes[key] = value; },
    appendChild(child) { this.children.push(child); this.firstChild = child; },
    addEventListener() {},
    querySelector(selector) { return this.children[selector] ||= {}; }
  })};
  let loaded;
  const sources = {}, layers = [];
  global.muniShell = () => ({mapStyle:() => ({version:8, sources:{}, layers:[]})});
  global.maplibregl = {
    Map:class {
      addControl() {}
      on(event, callback) { if (event === 'load') loaded = callback; }
      fitBounds() {}
      getSource(id) { return sources[id]; }
      addSource(id, source) { sources[id] = {...source, setData(data) { this.data = data; }}; }
      addLayer(layer) { layers.push(layer); }
      remove() {}
    },
    NavigationControl:class {},
    Marker:class {
      constructor({element}) { this.element = element; element.className += ' maplibregl-marker'; elements.push(this); }
      setLngLat(coords) { this.coords = coords; return this; }
      addTo() { return this; }
      getElement() { return this.element; }
      remove() { this.removed = true; }
    }
  };
  const mapApp = muniSubway();
  mapApp.stations = [{id:'station', name:'Station', routes:['Red','Green-B'], longitude:-71.1, latitude:42.3}];
  mapApp.vehicles = [
    {id:'train', route:'Red', longitude:-71.1, latitude:42.3, updated_at:stamp(-1000)},
    {id:'bad', route:'Blue', longitude:null, latitude:null, updated_at:stamp(-1000)}
  ];
  await mapApp.initMap();
  mapApp.get = async () => ({data:[{route:'Red', polyline:encoded}]});
  await mapApp.loadShapes();
  assert.equal(layers.length, 0, 'geometry waits until the map style loads');
  loaded();
  assert.equal(layers.length, 2, 'route casing and colored lines render');
  assert.equal(sources['subway-routes'].data.features.length, 1);
  assert.equal(elements.length, 2, 'invalid train coordinates never render at zero');
  assert.match(elements[0].element.className, /subway-marker--transfer/);
  assert.match(elements[0].element.className, /maplibregl-marker/, 'station updates preserve MapLibre positioning');
  assert.match(elements[1].element.innerHTML, /<svg/, 'trains have a distinct train pictogram');
  mapApp.vehicles[0].longitude = -71.09;
  mapApp.selectedStation = 'station';
  mapApp.renderMap();
  assert.equal(elements.length, 2, 'refresh preserves marker identity and keyboard focus');
  assert.deepEqual(elements[1].coords, [-71.09,42.3], 'existing train moves to its new position');
  assert.equal(elements[0].element.attributes['aria-pressed'], 'true');
  mapApp.vehicles[0].updated_at = stamp(-60000);
  mapApp.renderMap();
  assert.equal(elements[1].removed, true, 'stale trains disappear');
  mapApp.get = async () => { throw new Error('unavailable'); };
  await mapApp.loadShapes();
  assert.equal(mapApp.shapesError, 'Route lines unavailable.');
  assert.equal(elements[0].removed, undefined, 'geometry outages preserve station selection');
  mapApp.destroy();
}

Promise.all([testArrivals(), testMap()]).then(() => console.log('Subway geometry, markers, freshness and arrival tests passed.')).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
