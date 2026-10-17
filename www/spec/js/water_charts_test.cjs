const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const context = {window:{},URLSearchParams};
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../public/js/water-charts.js'),'utf8'),context);
const model = context.window.muniWaterChart.model.bind(context.window.muniWaterChart);
const series = values => ({points:values.map(value=>({value}))});
test('bars use a zero baseline and line segments break at missing observations',()=>{
  const chart=model([series([10,null,20])]);
  assert.equal(chart.low,0);
  assert.equal(chart.series[0].bars.length,2);
  assert.equal((chart.series[0].path.match(/M/g)||[]).length,2);
  assert.equal((chart.series[0].path.match(/L/g)||[]).length,0);
  assert.equal(chart.series[0].bars[0].height,70);
});
test('incompatible series have separate paths and finite zero/negative scales',()=>{
  const chart=model([series([0,0]),series([-10,-5])]);
  assert.equal(chart.series.length,2);
  assert.equal(chart.low,-10);
  assert.ok(chart.series.every(s=>!s.path.includes('NaN')));
  assert.ok(model([series([0,0])]).series[0].bars.every(b=>b.height===0));
});
test('line-only measurements use a labeled data range while bars retain their zero baseline',()=>{
  const chart=model([series([8.2,null,8.7])],false);
  assert.equal(chart.low,8.2);
  assert.equal(chart.high,8.7);
  assert.equal(chart.series[0].bars[0].pointY,170);
  assert.equal(model([series([8.2,8.7])]).low,0);
});
vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../../public/js/water.js'),'utf8'),context);
const app = context.window.muniWater();
test('discharge display keeps censored quantities and historical averages separate',()=>{
  assert.equal(app.dischargeValue({unit:'million gallons',payload:{event_volume:.14,volume_text:'0.14 MG | 0.22 MG (historical average)'}}),'0.14 million gallons');
  assert.equal(app.dischargeValue({payload:{volume_text:'< 0.01 MG | 0.22 MG (historical average)'}}),'< 0.01 MG');
  assert.equal(app.dischargeValue({payload:{volume_text:'0.22 MG (historical average)'}}),'Not supplied');
});
test('river view links preserve filters without inheriting a city',()=>{
  const river = context.window.muniWater();
  assert.equal(river.view,'metrics');
  Object.assign(river,{days:'custom',fromDate:'2026-07-01',toDate:'2026-07-31',location:'epa-buoy',recordSource:'water/charles/epa_buoy'});
  const url=new URL(river.viewUrl('datasets'),'http://localhost');
  assert.equal(url.pathname,'/water/charles');
  assert.equal(url.searchParams.get('view'),'datasets');
  assert.equal(url.searchParams.get('location'),'epa-buoy');
  assert.equal(url.searchParams.get('from'),'2026-07-01');
  assert.equal(url.searchParams.get('to'),'2026-07-31');
  assert.equal(url.searchParams.has('hall'),false);
});
test('dataset records clear measurement and geographic filters without mixing sources',async()=>{
  const river = context.window.muniWater();
  river.datasets=[{source:'water/charles/wqp',type:'laboratory'}];
  Object.assign(river,{reach:'5',location:'epa-buoy',recordParameter:'temperature',recordUnit:'deg C',recordMethod:'sensor'});
  river.changeView=async view=>{river.view=view;};
  await river.openSourceRecords({source_slug:'water/charles/wqp'});
  assert.equal(river.view,'records');
  assert.equal(river.recordSource,'water/charles/wqp');
  assert.equal(river.recordType,'laboratory');
  for(const key of ['reach','location','recordParameter','recordUnit','recordMethod']) assert.equal(river[key],'');
});
test('map selection keeps neighboring and unlocated places in the list and preserves reach filtering',()=>{
  const river=context.window.muniWater();
  river.data.locations=[
    {id:'buoy',name:'Buoy',kind:'sensor',reach_id:'5'},
    {id:'club',name:'Club',kind:'boathouse',reach_id:'5',geometry:{type:'Point',coordinates:[-71.1,42.3]}},
    {id:'station',name:'Station',kind:'laboratory',reach_id:'2'}
  ];
  river.location='buoy';
  assert.equal(river.selectedPlace().id,'buoy');
  assert.equal(river.mapRows().length,3);
  river.reach='5';
  assert.equal(river.mapRows().length,2);
  assert.ok(river.mapRows().some(row=>row.id==='club'));
  assert.ok(river.mapRows().some(row=>row.id==='buoy'));
});
test('display normalization preserves CFU/MPN distinctions and detection qualifiers',()=>{
  const river=context.window.muniWater();
  assert.equal(river.unit('cfu/100ml'),'CFU/100mL');
  assert.equal(river.unit('MPN/100ml'),'MPN/100mL');
  assert.equal(river.unit('ft^3/s'),'ft³/s');
  assert.equal(river.value({value:5,payload:{detection_condition:'Not Detected'}}),'Not detected');
  assert.equal(river.value({value:5,unit:'MPN/100mL',payload:{detection_condition:'Present Below Quantification Limit',detection_limit:'5',detection_unit:'MPN/100ml'}}),'< 5');
  assert.equal(river.value({value:5,unit:'CFU/100mL',payload:{detection_condition:'Present Below Quantification Limit',detection_limit:'5',detection_unit:'MPN/100ml'}}),'Below quantification');
});
test('sensor trends need three complete days; sparse notice charts need multiple published buckets',()=>{
  const river=context.window.muniWater();
  const data=points=>({series:[{points}]});
  const points=[{value:10},{value:11},{value:12}];
  assert.equal(river.chartHasData({type:'measurements',result:data(points)}),true);
  assert.equal(river.chartHasData({type:'predictions',result:data([{value:10},{value:11,partial:true}])}),false);
  assert.equal(river.chartHasData({type:'discharges',result:data([{value:1},{value:0}])}),false);
  assert.equal(river.chartHasData({type:'discharges',result:data([{value:1},{value:2}])}),true);
});
test('boathouse metrics count active publisher states, not retained reason text or collection runs',()=>{
  const river=context.window.muniWater();
  const dataset={source:'water/charles/crwa_boathouses',type:'states'};
  river.data.latest=[{source_slug:dataset.source,location_id:'a',payload:{active:false,reason:'Old warning'}},
    {source_slug:dataset.source,location_id:'b',payload:{active:true}}];
  assert.equal(river.summaryValue(dataset),'1 / 2');
  assert.equal(river.summaryUnit(dataset),'active overrides');
});
test('a historical sample opens its actual local date and method, not an empty current period',async()=>{
  const river=context.window.muniWater();
  const dataset={source:'water/charles/wqp',type:'laboratory',choice:'sample'};
  river.data.snapshots={samples:[{external_id:'sample',source_slug:dataset.source,location_id:'station',parameter:'ecoli',unit:'MPN/100mL',method:'A',observed_at:'2025-12-10T02:30:00Z'}]};
  river.changeView=async view=>{river.view=view;river.setRange();};
  await river.openRecords(dataset);
  assert.equal(river.view,'records');
  assert.equal(river.fromDate,'2025-12-09');
  assert.equal(river.toDate,'2025-12-09');
  assert.equal(river.rangeEnd,'2025-12-10');
  assert.equal(river.recordMethod,'A');
  assert.equal(river.recordUnit,'MPN/100mL');
});

test('date-only laboratory dates retain the publisher calendar date without a midnight conversion',()=>{
  const river=context.window.muniWater();
  assert.equal(river.observationStamp({observed_at:'2005-07-19T00:00:00Z',observed_date:'2005-07-19',time_precision:'date',payload:{}}),'2005-07-19 · date only');
  assert.equal(river.observationStamp({observed_at:'2005-07-19T00:00:00Z',payload:{time_precision:'date'}}),'Date not supplied');
});
test('irregular sample charts place observations by elapsed time',()=>{
  const chart=model([{points:[{date:'2026-01-01',value:10},{date:'2026-01-02',value:20},{date:'2026-01-11',value:30}]}],false);
  const bars=chart.series[0].bars;
  assert.equal(bars[0].pointX,50);
  assert.equal(bars[1].pointX,92);
  assert.equal(bars[2].pointX,470);
});
test('sparse observation charts keep the requested history visible instead of stretching the sampled period',()=>{
  const chart=model([{points:[{date:'2026-01-06',value:10},{date:'2026-01-11',value:20}]}],false,{from:'2026-01-01',to:'2026-01-11'});
  assert.equal(chart.series[0].bars[0].pointX,260);
  assert.equal(chart.series[0].bars[1].pointX,470);
});
test('chart dates use Eastern dates for timestamp bounds and preserve date-only sample dates',()=>{
  assert.equal(context.window.muniWaterChart.dateLabel('2026-10-17T00:30:00Z','none'),'10/16/26');
  assert.equal(context.window.muniWaterChart.dateLabel('2026-07-21','none'),'07/21/26');
});
test('laboratory calendar-day axes keep boundary-date samples inside rolling instant bounds',()=>{
  const dated={observed_date:'2026-10-16',time_precision:'date',value:10};
  const timed={observed_date:'2026-10-17',observed_at:'2026-10-17T10:30:00Z',time_precision:'time',value:20};
  const chart=model([{points:[dated,timed]}],false,{from:'2026-10-17T00:30:00Z',to:'2026-10-24T00:30:00Z',calendarDates:true});
  assert.equal(chart.series[0].bars[0].pointX,50);
  assert.equal(chart.series[0].bars[1].pointX,110);
  assert.equal(chart.series[0].bars[0].point.observed_at,undefined);
  assert.equal(chart.series[0].bars[1].point.observed_at,'2026-10-17T10:30:00Z');
});
test('program selectors use location names and equal-date sample conflicts remain explicit',()=>{
  const river=context.window.muniWater();
  river.data.locations=[{id:'club',name:'Rowing club'}];
  assert.equal(river.choiceLabel({kind:'program_state',location_id:'club'}),'Rowing club');
  const row={external_id:'a',selection_status:'multiple_distinct_results',selection_candidates:[{},{}]};
  const dataset={choice:'a',metricEntries:[{primary:row,confirmed_routine_candidates:[row,{external_id:'b'}]}]};
  assert.match(river.selectionExplanation(dataset),/2 distinct results/);
  assert.equal(river.companionCandidates(dataset)[0].external_id,'b');
});
test('evidence links preserve the displayed revision and cutoff after later corrections',async()=>{
  const river=context.window.muniWater();let request;
  river.get=async(path,params)=>{request={path,params};return {};};
  river.$nextTick=async()=>{};river.$refs={evidenceDialog:{showModal(){}}};
  await river.inspect({external_id:'sample/1',revision_id:42,revision_cutoff:100});
  assert.equal(request.path,'/evidence/sample%2F1');
  assert.equal(request.params.revision,42);assert.equal(request.params.cutoff,100);
});
test('observed edition intervals distinguish publisher clocks from collection observations',()=>{
  const river=context.window.muniWater();
  const edition={median_interval_seconds:1800,intervals_seconds:[1800,1800],basis:'publisher_timestamp'};
  assert.match(river.editionInterval({observed_editions:edition}),/Publisher timestamps: median 30 minutes/);
  edition.basis='first_observed_body_change';
  assert.match(river.editionInterval({observed_editions:edition}),/not guaranteed publisher timing/);
  assert.equal(river.editionInterval({}),'');
});
test('metric selectors preserve incompatible units and use the same server primary records as the map',()=>{
  const river=context.window.muniWater();
  const a={external_id:'cfu',kind:'laboratory',parameter:'ecoli',unit:'CFU/100mL',location_id:'a',source_slug:'water/charles/crwa_laboratory',payload:{}};
  const b={...a,external_id:'mpn',unit:'MPN/100mL',source_slug:'water/charles/wqp'};
  river.data={locations:[{id:'a',name:'Station A'}],latest:[a,b],metrics:[{id:'a',category:'contact',primary:a},{id:'b',category:'contact',primary:b}]};
  river.buildMetricCards();
  assert.equal(river.metricCards.length,2);
  assert.equal(river.metricGroups()[0].title,'Contact-related evidence');
  for(const card of river.metricCards)assert.ok(river.locationReadings('a').includes(river.choice(card)));
});
test('outfall details use the card notice snapshot and exclude withdrawn or ambiguous legacy rows',()=>{
  const river=context.window.muniWater();
  const notice={external_id:'notice',kind:'discharge',location_id:'CAM005',status:'published',unit:'million gallons',revision_id:42,payload:{event_volume:.14}};
  river.data={latest:[{...notice,external_id:'withdrawn',status:'retracted'},{...notice,external_id:'ambiguous',status:'needs_review'}],metrics:[{primary:notice}]};
  assert.equal(river.locationReadings('CAM005').length,1);
  assert.equal(river.locationReadings('CAM005')[0],notice);
  assert.equal(river.dischargeValue(river.locationReadings('CAM005')[0]),'0.14 million gallons');
});
test('laboratory history defaults to a year while explicitly selected periods apply to all charts',()=>{
  const river=context.window.muniWater();river.days='30';river.setRange();
  const lab=river.historyRange({type:'laboratory'}),sensor=river.historyRange({type:'measurements'});
  assert.ok(Math.abs((new Date(lab.to)-new Date(lab.from))/86400000-365)<.01);
  assert.ok(Math.abs((new Date(sensor.to)-new Date(sensor.from))/86400000-30)<.01);
  assert.equal(new URL(river.viewUrl(),'http://localhost').searchParams.has('days'),false);
  river.periodExplicit=true;
  assert.equal(river.historyRange({type:'laboratory'}).from,river.rangeStart);
});
test('records and exports explicitly request observation or publication presentation',()=>{
  const river=context.window.muniWater();river.setRange();
  assert.equal(river.recordParams().presentation,'observations');
  river.recordPresentation='publications';
  assert.equal(river.recordParams().presentation,'publications');
});
test('a qualified newer sample and older routine companion keep their own units and dates',()=>{
  const river=context.window.muniWater();
  const primary={external_id:'new',kind:'laboratory',location_id:'a',parameter:'ecoli',value:84,unit:'CFU/100mL',observed_date:'2026-07-21',time_precision:'date',payload:{sample_role:'unknown'}};
  const routine={...primary,external_id:'old',unit:'MPN/100mL',observed_date:'2025-12-09',payload:{sample_role:'routine'}};
  river.data={metrics:[{id:'ecoli',primary,qualified_latest:primary,confirmed_routine:routine}]};river.buildMetricCards();
  assert.equal(river.companion(river.metricCards[0]).external_id,'old');
  assert.match(river.companionLabel(routine),/MPN\/100mL.*2025-12-09/);
  assert.equal(river.eligibilityLabel(primary),'Sample role or method unconfirmed');
});

test('laboratory rendering produces isolated sample dots, while model lines are dashed',()=>{
  class Node {
    constructor(tag){this.tag=tag;this.attrs={};this.children=[];}
    setAttribute(name,value){this.attrs[name]=value;}
    append(node){this.children.push(node);}
    replaceChildren(){this.children=[];}
  }
  context.document={createElementNS(_ns,tag){return new Node(tag);}};
  const container=new Node('div');
  const data={aggregation:'observations',series:[{kind:'laboratory',unit:'CFU/100mL',points:[{date:'2026-01-01',value:10},{date:'2026-01-11',value:40}]}]};
  context.window.muniWaterChart.draw(container,data,'points');
  const children=container.children[0].children;
  assert.equal(children.filter(node=>node.tag==='circle').length,2);
  assert.equal(children.filter(node=>node.tag==='path'||node.tag==='rect').length,0);
  data.series[0].kind='prediction';
  context.window.muniWaterChart.draw(container,data,'line');
  assert.equal(container.children[0].children.find(node=>node.tag==='path').attrs['stroke-dasharray'],'5 3');
});

test('CSV export follows a fixed revision cursor and never resets the snapshot with offsets',async()=>{
  const river=context.window.muniWater();river.setRange();
  const requests=[];let exported;
  context.fetch=async url=>{
    requests.push(new URL(url,'http://localhost'));
    const first=requests.length===1;
    const headers={'X-Revision-Cutoff':'42','X-Next-Cursor':first ? 'next-page' : '', 'X-Next-Offset':first ? '5000' : ''};
    return {ok:true,headers:{get:name=>headers[name] || null},text:async()=>first ? 'id,value\na,1\n' : 'id,value\nb,2\n'};
  };
  context.Blob=class {constructor(chunks){exported=chunks.join('');}};
  context.URL={createObjectURL:()=>'/download',revokeObjectURL:()=>{}};
  context.document={body:{append:()=>{}},createElement:()=>({click(){},remove(){}})};
  await river.downloadCsv();
  assert.equal(river.error,'');
  assert.equal(requests.length,2);
  assert.equal(requests[0].searchParams.get('cursor'),'start');
  assert.equal(requests[1].searchParams.get('cursor'),'next-page');
  assert.equal(requests[1].searchParams.has('offset'),false);
  assert.equal(exported,'id,value\na,1\nb,2\n');
});

test('hourly model lines break across missing forecast hours',()=>{
  const chart=model([{kind:'prediction',points:[
    {observed_at:'2026-10-16T00:00:00Z',value:10},
    {observed_at:'2026-10-16T01:00:00Z',value:11},
    {observed_at:'2026-10-16T04:00:00Z',value:12}
  ]}],false);
  assert.equal((chart.series[0].path.match(/M/g)||[]).length,2);
  assert.equal((chart.series[0].path.match(/L/g)||[]).length,1);
});
