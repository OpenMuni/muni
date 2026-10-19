const assert = require('node:assert/strict');
const {fresh, muniSubway} = require('../../public/js/subway.js');

const now = Date.now();
const stamp = offset => new Date(now + offset).toISOString();
assert.equal(fresh(stamp(-1000), now), true);
assert.equal(fresh(stamp(-60000), now), false);
assert.equal(fresh(stamp(60000), now), false);
assert.equal(fresh('invalid', now), false);

global.localStorage = {getItem:()=>'place-harsq', setItem:()=>{}};
const app = muniSubway();
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

  app.listOpen = false;
  app.selectStation();
  assert.equal(app.listOpen, true, 'station selection opens arrivals on mobile');
  app.selectedStation = '';
  await app.loadPredictions();
  assert.deepEqual(app.predictions, [], 'clearing station clears arrivals');
}

testArrivals().then(() => console.log('Subway freshness and arrival tests passed.')).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
