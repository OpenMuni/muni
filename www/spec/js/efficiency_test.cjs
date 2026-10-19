const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../public/js/muni.js'), 'utf8');
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; };
const response = data => ({ok:true, json:async()=>data});
function shell(fetch, extra = {}) {
  const context = {window:{},URLSearchParams,AbortController,fetch,setTimeout,clearTimeout,setInterval:()=>0,...extra};
  vm.runInNewContext(source, context);
  const app = context.window.muniShell({hall:'cambridge',category:'service_requests'});
  Object.assign(app, {$nextTick:()=>{},reconcileSelectedRow:()=>{}});
  return {app,context};
}

test('late list responses cannot replace the current city or loading state', async()=>{
  const a=deferred(), b=deferred(); let calls=0;
  const {app}=shell(()=> (++calls===1 ? a.promise : b.promise));
  app.listScope='history';
  const old=app.loadRows(); app.hall='boston'; const current=app.loadRows();
  b.resolve(response({items:[{external_id:'new'}],next_cursor:null})); await current;
  a.resolve(response({items:[{external_id:'old'}],next_cursor:'bad'})); await old;
  assert.equal(app.rows[0].external_id,'new'); assert.equal(app.rowsLoading,false); assert.equal(app.nextCursor,null);
});

test('an obsolete facets response cannot replace new category facets', async()=>{
  const a=deferred(), b=deferred(); let calls=0;
  const {app}=shell(()=> (++calls===1 ? a.promise : b.promise));
  const old=app.loadFacets(); app.category='permits'; const current=app.loadFacets();
  b.resolve(response([{name:'new',values:['x']} ])); await current;
  a.resolve(response([{name:'old',values:['x']} ])); await old;
  assert.equal(app.facets[0].name,'new');
});

test('311 map view scroll appends cursor batches and history switches to the citywide list', async()=>{
  const urls=[];
  const {app}=shell(async url=>{urls.push(url);return response(urls.length===1 ?
    {items:[{hall:'cambridge',external_id:'same'},{hall:'boston',external_id:'same'}],next_cursor:'next'} :
    {items:[{hall:'cambridge',external_id:'same'},{hall:'cambridge',external_id:'new'}],next_cursor:null});});
  app.mapBbox='-71.2,42.3,-71,42.5';
  await app.loadRows();
  app.maybeLoadMore({target:{scrollHeight:1000,scrollTop:400,clientHeight:400}});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(app.rows.length,3);
  assert.deepEqual(app.rows.map(row=>row.hall),['cambridge','boston','cambridge']);
  assert.ok(urls[1].includes('cursor=next')); assert.ok(urls[1].includes('map_view=1'));
  assert.equal(app.nextCursor,null);
  app.set311ListScope('history'); await new Promise(resolve=>setImmediate(resolve));
  assert.ok(!urls[2].includes('map_view=1'));
});

test('311 scroll waits until near the bottom and never paginates another list', async()=>{
  let calls=0; const {app}=shell(async()=>{calls++;return response({items:[],next_cursor:null});});
  app.nextCursor='next';
  app.maybeLoadMore({target:{scrollHeight:2000,scrollTop:0,clientHeight:400}});
  app.category='permits';app.maybeLoadMore({target:{scrollHeight:1000,scrollTop:900,clientHeight:100}});
  assert.equal(calls,0);
});

test('failed 311 append keeps loaded rows and cursor for retry', async()=>{
  let fail=true; const {app}=shell(async()=>{if(fail)throw Error('network');return response({items:[{external_id:'next'}],next_cursor:null});});
  app.rows=[{external_id:'first'}];app.nextCursor='cursor';
  await app.loadMoreRows();
  assert.equal(app.rows.length,1);assert.equal(app.nextCursor,'cursor');assert.equal(app.loadMoreError,'network');
  fail=false;await app.loadMoreRows();
  assert.equal(app.rows.length,2);assert.equal(app.nextCursor,null);assert.equal(app.loadMoreError,null);
});

test('late 311 append cannot replace rows after a fresh query', async()=>{
  const old=deferred();let calls=0;
  const {app}=shell(()=>(++calls===1?old.promise:Promise.resolve(response({items:[{external_id:'fresh'}],next_cursor:null}))));
  app.listScope='history';
  app.rows=[{external_id:'old'}];app.nextCursor='cursor';
  const append=app.loadMoreRows();app.filters.status='Open';const fresh=app.loadRows();
  await fresh;old.resolve(response({items:[{external_id:'stale'}],next_cursor:'later'}));await append;
  assert.equal(app.rows[0].external_id,'fresh');assert.equal(app.rowsAppending,false);assert.equal(app.nextCursor,null);
});

test('the 311 list waits for the map viewport after facets resolve', async()=>{
  const {app}=shell(async()=>response([])); const wait=deferred(); const calls=[];
  app.categories=[{slug:'service_requests',default_widget:'map'}];
  Object.assign(app,{loadFacets:async()=>{calls.push('facets');},loadRows:()=>{calls.push('rows');return wait.promise;},maybeInitMap:async()=>{calls.push('map');},clearParkingLocationLayer:()=>{}});
  const pending=app.setCategory('service_requests'); await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(calls,['facets','map']); wait.resolve(); await pending;
});

test('initial map fetch waits for fitted bounds, ignores pre-load movement, and runs once', async()=>{
  const urls=[]; const events={}; let scheduled; let west=-71.1; let fits=0;
  const map={addControl:()=>{},on:(name,fn)=>{events[name]=fn;},isStyleLoaded:()=>false,
    getBounds:()=>({getWest:()=>west,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5})};
  const {app}=shell(async url=>{urls.push(url);return response({features:[],represented_count:0});},
    {setTimeout:fn=>{scheduled=fn;return 1;},clearTimeout:()=>{scheduled=null;},maplibregl:{Map:class {constructor(){return map;}},NavigationControl:class {}}});
  Object.assign(app,{$root:{dataset:{center:'[-71.1,42.37]'}},mapStyle:()=>({}),hallMaxBounds:()=>null,
    installHallBoundary:()=>{},fitMapToHall:()=>{fits++;west=-71.2;events.moveend();},
    enrichGeojson:x=>x,installGeoLayer:()=>{}});
  await app.maybeInitMap(); events.moveend(); await app.refreshGeo();
  assert.equal(scheduled,undefined); assert.equal(urls.length,0);
  events['style.load'](); await scheduled();
  assert.equal(urls.length,1); assert.ok(urls[0].includes('-71.200000'));
  events.load(); events.moveend(); await scheduled();
  assert.equal(fits,1); assert.equal(urls.length,1);
});

test('map results are scoped to filters and viewport, and unchanged URLs are suppressed', async()=>{
  const waits=[deferred(),deferred()];let calls=0;
  const {app}=shell(()=>waits[calls++].promise);
  const bounds={getWest:()=>-71.2,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5};
  app.map={getBounds:()=>bounds,isStyleLoaded:()=>true};app.enrichGeojson=x=>x;app.installGeoLayer=x=>{app.installed=x;};
  const old=app.refreshGeo();app.filters.status='Closed';const current=app.refreshGeo();
  waits[1].resolve(response({features:[],represented_count:7}));await current;
  waits[0].resolve(response({features:[],represented_count:9}));await old;
  assert.equal(app.geoFeatureCount,7);await app.refreshGeo();assert.equal(calls,2);
});

test('the 311 list reloads with the exact map viewport after a pan',async()=>{
  const urls=[];
  const {app}=shell(async url=>{
    urls.push(url);
    return response(url.includes('/map?') ?
      {features:[],represented_count:0,bbox:[-71.2,42.3,-71,42.5]} : {items:[],next_cursor:null});
  });
  app.map={getBounds:()=>({getWest:()=>-71.2,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5}),isStyleLoaded:()=>true};
  app.installGeoLayer=()=>{};
  await app.refreshGeo();
  assert.ok(urls[0].includes('/map?'));
  assert.ok(urls[1].includes('map_view=1'));
  assert.ok(urls[1].includes('bbox=-71.2%2C42.3%2C-71%2C42.5'));
});

test('individual server-verified 311 points are not filtered again in the browser',()=>{
  const {app}=shell(); app.featureAnchorCoords=()=>[-71,42];app.pointInHallBoundary=()=>false;
  const data=app.enrichGeojson({features:[{properties:{external_id:'one',map_signal:'open'},geometry:{type:'Point',coordinates:[-71,42]}}]});
  assert.equal(data.features.length,1);
});

test('311 dots use the four explained map signals and history is grey',()=>{
  const {app}=shell();
  const colors=app.mapPointColor();
  assert.equal(colors[0],'match');
  for(const signal of ['open','acknowledged','no_recent_update','other_active']) {
    assert.ok(colors.includes(signal));
    assert.equal(app.dotClassFromRow({map_signal:signal}),`map_${signal}`);
  }
  assert.equal(app.dotClassFromRow({status:'Closed'}),'history');
});

test('a 311 pan updates point data without rebuilding the map layers',()=>{
  let updated=0;
  const source={setData:()=>{updated++;}};
  const {app}=shell();
  app.map={isStyleLoaded:()=>true,getSource:()=>source,getLayer:()=>({})};
  app._installedGeoCategory='service_requests';
  app.updateSelectedMapFilter=()=>{};
  app.clearMapLayers=()=>{throw Error('layers rebuilt');};
  app.installGeoLayer({type:'FeatureCollection',features:[]});
  assert.equal(updated,1);
});

test('an unchanged viewport refreshes lifecycle and age eligibility even without streams', async()=>{
  let calls=0;
  const {app}=shell(async()=>{ calls++; return response({features:[],represented_count:0}); });
  app.map={getBounds:()=>({getWest:()=>-71.2,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5}),isStyleLoaded:()=>true};
  app.enrichGeojson=x=>x;app.installGeoLayer=()=>{};
  await app.refreshGeo();await app.refreshGeo();assert.equal(calls,1);
  await app.refresh311Lifecycle();assert.equal(calls,2);
  app.category='trees';await app.refresh311Lifecycle();assert.equal(calls,2);
});

test('a failed current 311 refresh clears stale map features', async()=>{
  const {app}=shell(async()=>{throw new Error('unavailable');});
  app.map={getBounds:()=>({getWest:()=>-71.2,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5}),isStyleLoaded:()=>true};
  app.installGeoLayer=x=>{app.installed=x;};
  await app.refreshGeo();assert.equal(app.installed.features.length,0);assert.equal(app.mapError,'unavailable');
});

test('overlapping dots offer each request for selection',async()=>{
  const first={properties:{hall:'cambridge',external_id:'one',case_type:'Pothole'},geometry:{type:'Point',coordinates:[-71.1,42.37]}};
  const second={properties:{hall:'cambridge',external_id:'two',case_type:'Street light'},geometry:{type:'Point',coordinates:[-71.1,42.37]}};
  const {app}=shell();app.map={queryRenderedFeatures:()=>[first,second]};
  app.onMapPointClick({point:{x:10,y:10},features:[first]});
  assert.deepEqual(app.nearbyRequests.map(row=>row.external_id),['one','two']);
  app.select=()=>{};app.isMobileViewport=()=>false;
  app.selectNearbyRequest(app.nearbyRequests[1]);
  assert.equal(app.nearbyRequests.length,0);
});

test('late selected-ticket details cannot replace a newer selection',async()=>{
  const a=deferred(),b=deferred();let calls=0;
  const {app}=shell(()=>(++calls===1?a.promise:b.promise));
  const first={hall:'cambridge',external_id:'a'},second={hall:'cambridge',external_id:'b'};
  app.selected=first;const old=app.loadSelectedDetail(first);app.selected=second;const current=app.loadSelectedDetail(second);
  b.resolve(response({description:'new'}));await current;a.resolve(response({description:'old'}));await old;
  assert.equal(app.selected.external_id,'b');assert.equal(app.selected.description,'new');
});

test('viewport movement rejects a late map response before the debounced replacement starts', async()=>{
  const pending=deferred();const {app}=shell(()=>pending.promise);let west=-71.2;
  app.map={getBounds:()=>({getWest:()=>west,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5}),isStyleLoaded:()=>true};
  app.enrichGeojson=x=>x;app.installGeoLayer=()=>{throw Error('obsolete viewport installed');};
  const old=app.refreshGeo();west=-71.15;pending.resolve(response({features:[],represented_count:7}));await old;
  assert.equal(app.geoFeatureCount,null);
});

test('late failed details from another hall cannot set an error on the same external ID', async()=>{
  let reject;const pending=new Promise((_,fail)=>{reject=fail;});const {app}=shell(()=>pending);
  const first={hall:'cambridge',external_id:'same'};app.selected=first;const old=app.loadSelectedDetail(first);
  app.hall='boston';app.selected={hall:'boston',external_id:'same'};reject(Error('old failure'));await old;
  assert.equal(app.detailError,null);
});


test('MapLibre methods receive the raw map rather than Alpine reactive proxies',()=>{
  let resized=false;
  const map={resize(){assert.equal(this,map);resized=true;}};
  const proxy={};
  const {app,context}=shell();app.map=proxy;
  context.window.Alpine={raw:value=>{assert.equal(value,proxy);return map;}};
  app.resizeMap();assert.equal(resized,true);
});

test('map responses wait for a replacement style, not the one-time map load event',async()=>{
  const {app}=shell(async()=>response({features:[],represented_count:3}));let event,install;
  app.map={getBounds:()=>({getWest:()=>-71.2,getSouth:()=>42.3,getEast:()=>-71,getNorth:()=>42.5}),isStyleLoaded:()=>false,once:(name,fn)=>{event=name;install=fn;}};
  app.enrichGeojson=x=>x;let installed=false;app.installGeoLayer=()=>{installed=true;};
  await app.refreshGeo();assert.equal(event,'style.load');assert.equal(installed,false);install();assert.equal(installed,true);
});


test('a loaded style remains ready for layers while tile sources load',()=>{
  const {app}=shell();app.map={isStyleLoaded:()=>false};
  assert.equal(app.mapStyleReady(),false);app._mapStyleLoaded=true;
  assert.equal(app.mapStyleReady(),true);
});


test('cluster labels use a font available from the configured basemap glyph service',()=>{
  const {app}=shell();app.map={getStyle:()=>({layers:[{layout:{'text-font':['Existing Font']}}]})};
  assert.deepEqual(Array.from(app.clusterTextFont()),['Existing Font']);
  app.map={getStyle:()=>({layers:[]})};assert.deepEqual(Array.from(app.clusterTextFont()),['Noto Sans Regular']);
});
