const assert = require('node:assert/strict');
const {fresh, duePredictions, muniSubway} = require('../../public/js/subway.js');

const now = Date.now();
const stamp = offset => new Date(now + offset).toISOString();
const prediction = {id:'prediction-1', route:'Red', arrival_time:stamp(120000), updated_at:stamp(-1000)};

assert.equal(fresh(stamp(-1000), now), true);
assert.equal(fresh(stamp(-60000), now), false);
assert.equal(duePredictions([prediction], stamp(-1000), now, new Set()).length, 1);
assert.equal(duePredictions([prediction], stamp(-60000), now, new Set()).length, 0);
assert.equal(duePredictions([{...prediction, updated_at:stamp(-60000)}], stamp(-1000), now, new Set()).length, 0);
assert.equal(duePredictions([prediction], stamp(-1000), now, new Set(['prediction-1'])).length, 0);
assert.equal(duePredictions([{...prediction, updated_at:undefined}], stamp(-1000), now, new Set()).length, 1);

global.localStorage = {getItem:()=>'place-harsq', setItem:()=>{}};
let notifications = 0;
global.Notification = class {static permission = 'granted'; constructor() { notifications += 1; }};
const app = muniSubway();
app.selectedStation = 'place-harsq';
app.stations = [{id:'place-harsq', name:'Harvard'}];
app.predictions = [prediction];
app.predictionsFetchedAt = stamp(-1000);
app.notifyArrivals();
assert.equal(notifications, 0, 'notifications start disabled');
app.notificationsEnabled = true;
app.notifyArrivals();
app.notifyArrivals();
assert.equal(notifications, 1, 'one notification per real prediction');
app.predictions = [{...prediction, id:'prediction-2', updated_at:stamp(-60000)}];
app.notifyArrivals();
assert.equal(notifications, 1, 'stale prediction is suppressed');
app.predictionsFetchedAt = stamp(-60000);
app.predictions = [{...prediction, id:'prediction-3'}];
app.notifyArrivals();
assert.equal(notifications, 1, 'stale response is suppressed');

console.log('Subway freshness and notification tests passed.');
