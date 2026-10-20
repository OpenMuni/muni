const assert = require('node:assert/strict');
const { initializePreferences } = require('../../public/js/account-preferences.js');

function option(value, dataset = {}) {
  return { value, dataset, cloneNode() { return option(value, dataset); } };
}

function select(options, value = '') {
  return {
    options, value, listeners: {},
    get selectedOptions() { return this.options.filter(o => o.value === this.value); },
    addEventListener(name, callback) { this.listeners[name] = callback; },
    replaceChildren(...children) { this.options = children; },
    change(value) { this.value = value; this.listeners.change(); }
  };
}

function form(cityValue = '', lineValue = '', stationValue = '') {
  const city = select([
    option(''), option('boston', {network:'mbta'}), option('cambridge', {network:'mbta'}),
    option('future-city', {network:'other'})
  ], cityValue);
  const line = select(['', 'Red', 'Blue', 'Green-B'].map(v => option(v)), lineValue);
  const station = select([
    option(''), option('place-harsq', {routes:'Red'}),
    option('place-pktrm', {routes:'Red Green-B'}), option('place-gover', {routes:'Blue Green-B'})
  ], stationValue);
  const group = {hidden:false};
  const fields = {'#hall':city, '#home-station':group, '#home-station-line':line, '#home-station-id':station};
  initializePreferences({querySelector: id => fields[id]});
  return {city, line, station, group};
}

const fresh = form();
assert.equal(fresh.group.hidden, true, 'station choices wait for a supported city');
fresh.city.change('boston');
assert.equal(fresh.group.hidden, false);
assert.deepEqual(fresh.station.options.map(o => o.value), [''], 'a line is chosen before a station');
fresh.line.change('Red');
assert.deepEqual(fresh.station.options.map(o => o.value), ['', 'place-harsq', 'place-pktrm']);
fresh.station.value = 'place-pktrm';
fresh.line.change('Green-B');
assert.equal(fresh.station.value, 'place-pktrm', 'transfer stations survive a change to another serving line');
assert.deepEqual(fresh.station.options.map(o => o.value), ['', 'place-pktrm', 'place-gover']);
fresh.city.change('cambridge');
assert.equal(fresh.station.value, 'place-pktrm', 'Boston and Cambridge share the same network');
fresh.line.change('Blue');
assert.equal(fresh.station.value, '', 'a station not on the new line is cleared');
fresh.station.value = 'place-gover';
fresh.line.change('');
assert.equal(fresh.station.value, '', 'clearing the line clears the station');

const saved = form('cambridge', 'Red', 'place-harsq');
assert.equal(saved.station.value, 'place-harsq', 'saved station survives initialization');
assert.equal(saved.line.value, 'Red');
saved.city.change('future-city');
assert.equal(saved.group.hidden, true, 'unsupported networks hide MBTA');
assert.equal(saved.line.value, '');
assert.equal(saved.station.value, '', 'switching networks clears incompatible preferences');

const outageCity = select([option('boston', {network:'mbta'})], 'boston');
const outageGroup = {hidden:false};
assert.doesNotThrow(() => initializePreferences({
  querySelector: id => ({'#hall':outageCity, '#home-station':outageGroup}[id] || null)
}), 'city saving remains usable when the station catalog is unavailable');
console.log('Account preference controls: city, lines, transfers, restoration, clearing and outages passed.');
