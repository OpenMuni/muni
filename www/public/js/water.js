window.muniWater = function () {
  let map = null;
  const datasetDefinitions = [
    ['epa_buoy','EPA buoy','measurements','temperature'], ['usgs','USGS · Waltham','measurements','flow'],
    ['crwa_predictions','CRWA predictions','predictions','ecoli'], ['crwa_boathouses','CRWA boathouses','states',null],
    ['wqp','E. coli · WQP','laboratory',null], ['crwa_laboratory','E. coli · CRWA','laboratory',null],
    ['cambridge_cso','Discharges · Cambridge','discharges',null], ['mwra_cso','Discharges · MWRA','discharges',null]
  ];
  return {
    view:'metrics', days:'30', fromDate:'', toDate:'', reach:'', location:'', data:{}, datasets:[], metricCards:[],
    loading:true, error:'', exporting:false, detail:null, selectedSignal:null, signals:[],
    recordPresentation:'observations', periodExplicit:false, recordType:'measurements', recordSource:'', recordParameter:'', recordUnit:'', recordMethod:'',
    records:[], recordsTotal:0, recordsOffset:0, recordsNext:null, recordsLoading:false, recordsRequest:0,
    rangeStart:'', rangeEnd:'', signalsRequest:0,
    mobileListOpen:false, mapFilterOpen:false, hoveredLocation:null, mapError:'',
    async init() {
      const query = new URLSearchParams(window.location.search);
      this.view = ['metrics','map','records','datasets'].includes(query.get('view')) ? query.get('view') : 'metrics';
      this.days = ['7','30','90','365','custom'].includes(query.get('days')) ? query.get('days') : '30';
      this.periodExplicit=query.has('days');
      this.recordPresentation=query.get('presentation')==='publications' ? 'publications' : 'observations';
      this.fromDate = query.get('from') || ''; this.toDate = query.get('to') || '';
      this.reach = ['2','3','4','5'].includes(query.get('reach')) ? query.get('reach') : ''; this.location = query.get('location') || '';
      this.recordSource = query.get('source') || ''; this.recordParameter = query.get('parameter') || '';
      this.recordUnit = query.get('unit') || ''; this.recordMethod = query.get('method') || '';
      this.recordType = ['measurements','laboratory','predictions','discharges','changes','states'].includes(query.get('type')) ? query.get('type') : 'measurements';
      try {
        this.data = await this.get('/metrics');
        this.datasets = datasetDefinitions.map(([id,title,type,parameter]) => {
          const source = 'water/charles/' + id;
          const choices = this.sourceChoices({source,type});
          const choice = choices.find(row => row.parameter === parameter) || choices[0];
          return {id,title,type,source,choice:choice?.external_id || '',result:null,loading:false,error:'',request:0};
        });
        this.buildMetricCards();
        if(!this.sortedLocations().some(row=>row.id===this.location))this.location='';
        this.loading = false;
        await this.$nextTick();
        if(this.$refs.locationSelect)this.$refs.locationSelect.value=this.location;
        if(this.$refs.sourceSelect)this.$refs.sourceSelect.value=this.recordSource;
        await this.refresh();
      } catch(error) { this.error = 'Data unavailable. ' + error.message; }
      finally { this.loading = false; }
    },
    async get(path, params = {}) {
      // The metrics snapshot supplies coverage. Dependent reads keep their own
      // revision/provenance fields without resending the same source metadata.
      const query = path === '/metrics' || path === '/coverage' ? params : {...params,include_coverage:'0'};
      const response = await fetch('/api/water/charles' + path + '?' + new URLSearchParams(query));
      const body = await response.json();
      if (!response.ok) throw new Error(body.error || 'Data unavailable');
      return body;
    },
    label(value) {
      const labels = {temperature:'Temperature',dissolved_oxygen:'Dissolved oxygen',turbidity:'Turbidity',ph:'pH',ecoli:'E. coli',flow:'River flow',level:'Gage height',
        estimated_chlorophyll_a:'Chlorophyll a · estimated',estimated_cyanobacteria:'Cyanobacteria · estimated',
        gauge:'Upstream gauge',derived_sensor:'EPA estimate',sensor:'Sensor',laboratory:'Lab sample',prediction:'Prediction',
        program_state:'Program state',historical_data_only:'Historical',see_source_coverage:'Historical',
        conductivity:'Conductivity',oxygen_saturation:'Oxygen saturation',chlorophyll:'Chlorophyll fluorescence',phycocyanin:'Phycocyanin fluorescence',
        current_publisher_state:'Current',current:'Current',stale:'Stale',out_of_season:'Out of season',insufficient_evidence:'No readings',
        missing:'Missing',collection_interrupted:'Collection interrupted',checking:'On schedule',sustained_sensor_shift:'Measurement shift'};
      return labels[value] || String(value ?? 'Not supplied').replaceAll('_',' ');
    },
    stamp(value) {
      if (!value) return 'Not supplied';
      if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
      return new Date(value).toLocaleString('en-US',{timeZone:'America/New_York',month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit',timeZoneName:'short'});
    },
    unit(value) {
      const key=String(value || '').trim().toLowerCase().replaceAll(' ','');
      return {'cfu/100ml':'CFU/100mL','mpn/100ml':'MPN/100mL','ft^3/s':'ft³/s','ug/l':'µg/L','µg/l':'µg/L','mg/l':'mg/L','ms/cm':'mS/cm','rfu':'RFU','fnu':'FNU','ph':'pH'}[key] || value || '';
    },
    value(row, precision=3) {
      const payload=row?.payload || {};
      const condition=payload.detection_condition;
      if(condition==='Not Detected') return payload.detection_limit ? 'Not detected · below ' + payload.detection_limit : 'Not detected';
      if(condition?.includes('Quantification Limit')) {
        const above=condition.includes('Above');
        const compatible=!payload.detection_unit || this.unit(payload.detection_unit)===this.unit(row.unit);
        return payload.detection_limit && compatible ? `${above ? '>' : '<'} ${payload.detection_limit}` : `${above ? 'Above' : 'Below'} quantification`;
      }
      if(payload.comparator && payload.limit_value != null) return `${payload.comparator} ${payload.limit_value}`;
      if (row?.value == null) return payload.original_value || '—';
      const value = Number(row.value).toLocaleString('en-US',{maximumFractionDigits:precision});
      return payload.qualifier ? `${value} · ${payload.qualifier}` : value;
    },
    dischargeValue(row) {
      const payload=row.payload || {};
      if(payload.event_volume != null) return `${Number(payload.event_volume).toLocaleString('en-US',{maximumFractionDigits:3})} ${row.unit || 'million gallons'}`;
      return payload.volume_text?.split('|').map(text=>text.trim()).find(text=>text && !/average|last three years/i.test(text)) || 'Not supplied';
    },
    observationStamp(row) {
      if ((row.time_precision || row.payload?.time_precision) !== 'date') return this.stamp(row.observed_at);
      const date=row.observed_date || row.payload?.event_date;
      return date ? date + ' · date only' : 'Date not supplied';
    },
    locationName(id) { return this.data.locations?.find(row => row.id === id)?.name || id || 'Not supplied'; },
    sourceName(slug) { return this.datasets.find(row=>row.source===slug)?.title || slug; },
    status(dataset) { const source=this.choice(dataset)?.source_slug || dataset.source; return this.data.source_coverage?.find(row=>row.source_slug===source || row.id===dataset.id) || {}; },
    viewTitle() { return {metrics:'Charles River',map:'Map',records:'Records',datasets:'Datasets'}[this.view]; },
    cadence(seconds) {
      if (!seconds) return 'Not collected';
      if (seconds === 604800) return 'Weekly';
      if (seconds === 86400) return 'Daily';
      if (seconds % 3600 === 0) return seconds === 3600 ? 'Hourly' : `Every ${seconds / 3600} hours`;
      return `Every ${seconds / 60} minutes`;
    },
    duration(seconds) {
      const value=Number(seconds);
      if(value<60)return `${Math.round(value)} seconds`;
      if(value<3600)return `${Number((value/60).toFixed(1))} minutes`;
      if(value<86400)return `${Number((value/3600).toFixed(1))} hours`;
      return `${Number((value/86400).toFixed(1))} days`;
    },
    editionInterval(source) {
      const edition=source.observed_editions,seconds=edition?.median_interval_seconds;
      if(seconds==null)return '';
      const interval=`median ${this.duration(seconds)} across ${edition.intervals_seconds?.length || 0} observed intervals`;
      return edition.basis==='publisher_timestamp' ? `Publisher timestamps: ${interval}.` : `First observed body changes: ${interval}. These are collection observations, not guaranteed publisher timing.`;
    },
    warnings() { return [...(this.data.advisories || []),...(this.data.latest || []).filter(row=>row.kind==='program_state' && row.payload.active)]; },
    warningLabel(row) { return row.kind === 'official_advisory' ? `${row.payload.issuer}: ${row.payload.title} · ${row.expiry_state}` : `${this.locationName(row.location_id)}: ${row.payload.reason || 'Active CRWA override'}`; },
    sortedLocations() {
      return [...(this.data.locations || [])].filter(row=>row.kind!=='waterbody' && (!this.reach || row.reach_id===this.reach))
        .sort((a,b)=>a.name.localeCompare(b.name));
    },
    sourceChoices(dataset) {
      if(dataset.metricEntries) return dataset.metricEntries.map(entry=>entry.primary).filter(Boolean);
      const rows=dataset.type==='laboratory' ? this.data.snapshots?.samples : this.data.latest;
      return (rows || []).filter(row=>row.source_slug===dataset.source && (row.parameter || dataset.type==='states'))
        .sort((a,b)=>String(b.observed_at || '').localeCompare(String(a.observed_at || '')) || a.location_id.localeCompare(b.location_id));
    },
    choices(dataset) { return this.sourceChoices(dataset).filter(row=>(!this.reach || row.reach_id===this.reach) && (!this.location || row.location_id===this.location)); },
    choice(dataset) { return this.choices(dataset).find(row=>row.external_id===dataset.choice); },
    choiceLabel(row) {
      if(row.kind==='laboratory') {
        const name=this.locationName(row.location_id).replace(/^Charles River (\d+S) \((.*)\)$/, '$1 · $2');
        const peers=(this.data.snapshots?.samples || []).filter(other=>other.source_slug===row.source_slug && other.location_id===row.location_id && other.unit===row.unit);
        return `${name} · ${this.unit(row.unit)} · ${this.sourceName(row.source_slug)}` + (peers.length>1 ? ` · ${row.method || 'Method unspecified'} · ${row.segment || 'Segment unspecified'} · ${this.value(row)} · ${this.observationStamp(row)}` : '');
      }
      if(['prediction','program_state'].includes(row.kind)) return this.locationName(row.location_id);
      return this.label(row.parameter) + (row.parameter==='ph' ? '' : ` · ${this.unit(row.unit)}`);
    },
    buildMetricCards() {
      const groups=new Map();
      for(const metric of this.data.metrics || []) {
        const row=metric.primary || metric.qualified_latest || metric.confirmed_routine;
        const kind=row?.kind;
        const type=({sensor:'measurements',derived_sensor:'measurements',gauge:'measurements',laboratory:'laboratory',prediction:'predictions',discharge:'discharges',program_state:'states'})[kind] || metric.type || 'measurements';
        const key=row ? [row.parameter || kind,kind,this.unit(row.unit),row.method || '',row.segment || '',type==='discharges' ? row.source_slug : ''].join('|') : metric.id;
        if(!groups.has(key)) groups.set(key,{id:'metric-'+groups.size,title:type==='predictions' ? 'Modeled E. coli' : type==='laboratory' ? 'E. coli samples' : type==='states' ? 'CRWA program overrides' : type==='discharges' ? this.sourceName(row?.source_slug) : this.label(metric.parameter || row?.parameter || kind),type,source:row?.source_slug || metric.source_slug,parameter:metric.parameter || row?.parameter,category:metric.category || (kind==='gauge' ? 'flow' : ['laboratory','prediction','discharge','program_state'].includes(kind) ? 'contact' : 'aquatic'),choice:row?.external_id || '',metricEntries:[],result:null,loading:false,error:'',request:0});
        groups.get(key).metricEntries.push({...metric,primary:row});
      }
      this.metricCards=[...groups.values()];
      for(const card of this.metricCards) {
        card.metricEntries.sort((a,b)=>String(b.primary?.observed_date || b.primary?.observed_at || '').localeCompare(String(a.primary?.observed_date || a.primary?.observed_at || '')));
        card.choice=card.metricEntries[0]?.primary?.external_id || '';
      }
      // Keep the publisher catalog separate from the metric-oriented display.
      if(!this.metricCards.length) this.metricCards=this.datasets;
      else for(const dataset of this.datasets.filter(row=>['states','discharges'].includes(row.type))) {
        if(!this.metricCards.some(card=>card.source===dataset.source && card.type===dataset.type))this.metricCards.push({...dataset,category:'contact'});
      }
    },
    metricEntry(dataset) { return dataset.metricEntries?.find(entry=>entry.primary?.external_id===dataset.choice) || dataset.metricEntries?.[0] || {}; },
    companion(dataset) {
      const entry=this.metricEntry(dataset),primary=this.choice(dataset);
      const row=entry.confirmed_routine;
      return row && row.external_id!==primary?.external_id ? row : null;
    },
    companionCandidates(dataset) {
      const candidates=this.metricEntry(dataset).confirmed_routine_candidates || [];
      return candidates.length>1 ? candidates.filter(row=>row.external_id!==this.choice(dataset)?.external_id) : [];
    },
    selectionExplanation(dataset) {
      const row=this.choice(dataset);
      return row?.selection_status==='multiple_distinct_results' ? `${row.selection_candidates?.length || 'Multiple'} distinct results share this latest sample date. No result is preferred; use the selector to inspect each.` : '';
    },
    qualifiedCompanion(dataset) {
      const row=this.metricEntry(dataset).qualified_latest,primary=this.choice(dataset);
      return row && row.external_id!==primary?.external_id ? row : null;
    },
    companionLabel(row) { return `${this.value(row)} ${this.unit(row.unit)} · ${this.observationStamp(row)}`; },
    eligibilityLabel(row) {
      if(['quality_control','qc'].includes(row?.payload?.sample_role) || (row?.payload?.sample_role == null && row?.payload?.routine_sample===false)) return 'Quality-control sample';
      if(row?.payload?.sample_role==='routine' || row?.payload?.routine_sample===true) return 'Confirmed routine sample';
      return row?.kind==='laboratory' ? 'Sample role or method unconfirmed' : this.label(row?.status);
    },
    metricGroups() {
      return [
        {title:'Contact-related evidence',category:'contact',description:'Dated samples, modeled E. coli and reported notices. These do not establish whether the river is safe for contact.'},
        {title:'Aquatic conditions',category:'aquatic',description:'Local measurements at the EPA buoy outside the Museum of Science, 1 m below the surface. They do not represent the whole river.'},
        {title:'River flow',category:'flow',description:'Waltham is an upstream gauge. Gage height is measured relative to a local datum, not the depth of the river.'}
      ].map(group=>({...group,datasets:this.metricCards.filter(dataset=>(dataset.category || ({measurements:dataset.source?.endsWith('/usgs') ? 'flow' : 'aquatic',laboratory:'contact',predictions:'contact',discharges:'contact',states:'contact'})[dataset.type])===group.category && (dataset.metricEntries?.some(entry=>!entry.primary) || (dataset.type==='discharges' ? !this.location || this.selectedPlace()?.kind==='outfall' : this.choices(dataset).length>0)))})).filter(group=>group.datasets.length);
    },
    coverageLabel(dataset) {
      if(dataset.type==='states')return `${this.choices(dataset).length} CRWA program locations · not measurements`;
      if(dataset.type==='discharges')return `${this.sourceName(dataset.source)} · selected outfalls only`;
      const entry=this.metricEntry(dataset);
      if(typeof entry.coverage==='string') return entry.coverage;
      if(entry.coverage?.label) return entry.coverage.label;
      if(entry.coverage?.summary) return entry.coverage.summary;
      const row=this.choice(dataset);
      return row ? `${this.locationName(row.location_id)} · ${row.kind==='prediction' ? 'one modeled reach' : 'one location'}` : 'No eligible evidence for this selection';
    },
    metricLimitation(dataset) {
      const row=this.choice(dataset);
      if(row?.parameter==='estimated_cyanobacteria') return 'EPA estimate derived from a buoy sensor. This is not a laboratory cell count or a toxin measurement.';
      if(['chlorophyll','phycocyanin'].includes(row?.parameter)) return 'Fluorescence at this instrument, not a measured toxin concentration or organism count.';
      if(dataset.type==='laboratory') return 'A dated sample describes its collection time. CFU and MPN results and methods remain separate.';
      if(dataset.type==='states') return 'A publisher program override is not a measurement or a complete official advisory service.';
      return this.metricEntry(dataset).limitation || row?.payload?.limitation || '';
    },
    historyRange(dataset) {
      if(dataset.type==='laboratory' && !this.periodExplicit && this.days!=='custom') return {from:new Date(Date.now()-365*86400000).toISOString(),to:this.rangeEnd};
      return this.range();
    },
    chartStamp(point,dataset) { return dataset.type==='laboratory' ? this.observationStamp(point) : (dataset.type==='predictions' || dataset.result?.aggregation==='hour') ? this.stamp(point.observed_at) : point.date || point.observed_date || this.stamp(point.observed_at); },
    chartRows(dataset) { return (dataset.result?.series || []).flatMap(series=>series.points.map(point=>({...point,unit:series.unit,method:series.method,segment:series.segment}))); },
    chartHasData(dataset) {
      const series=dataset.result?.series || [];
      return series.some(series=>{
        const points=series.points.filter(point=>point.value!=null);
        return dataset.type==='discharges' ? points.filter(point=>point.value>0).length>=2 : dataset.type==='laboratory' ? points.length>0 : dataset.type==='predictions' ? points.filter(point=>!point.partial).length>1 : points.filter(point=>!point.partial).length>=3;
      });
    },
    chartMode(dataset) { return dataset.type==='laboratory' ? 'points' : dataset.type==='discharges' ? 'bars' : this.choice(dataset)?.parameter==='ph' || this.choice(dataset)?.kind==='derived_sensor' || dataset.type==='predictions' ? 'line' : 'both'; },
    chartLabel(dataset) {
      if(dataset.type==='discharges') return 'Published notices / ' + (dataset.result?.aggregation || 'day');
      if(dataset.type==='laboratory') return 'Dated samples · ' + this.unit(this.choice(dataset)?.unit) + ' · ' + (!this.periodExplicit ? 'past year' : 'selected period');
      if(dataset.type==='predictions') return (dataset.result?.aggregation==='day' ? 'Daily median of CRWA predictions' : 'Hourly CRWA predictions') + ' · dashed line · ' + this.unit(this.choice(dataset)?.unit);
      return 'Daily median · ' + this.unit(this.choice(dataset)?.unit) + ' · ≥80% coverage';
    },
    chartEmptyLabel(dataset) {
      if(!dataset.result?.record_count) return dataset.type==='laboratory' ? 'No samples in this period' : 'No readings in this period';
      if(dataset.type==='laboratory') return 'No exact numeric sample results to plot. Qualified and bounded results remain in Records.';
      return 'Insufficient daily coverage for a trend';
    },
    snapshot(dataset) { return this.data.snapshots?.discharges?.find(row=>row.source_slug===dataset.source) || {}; },
    metricStatus(dataset) {
      if(dataset.type==='laboratory') return this.choice(dataset)?.eligibility?.calculation===false ? 'Qualified sample' : 'Dated sample';
      if(dataset.type==='discharges') return 'Reported notices';
      if(this.status(dataset).status==='out_of_season') return 'Out of season';
      if(dataset.type==='states') return this.label(this.status(dataset).status);
      const row=this.choice(dataset);
      if(!row || row.value==null) return 'No reading';
      const allowance=this.status(dataset).allowance_seconds || 7200;
      return Date.now()-new Date(row.observed_at).getTime() > allowance*1000 ? 'Stale' : 'Current';
    },
    summaryValue(dataset) {
      if(dataset.type==='discharges') return dataset.error ? '—' : dataset.result?.record_count ?? '—';
      if(dataset.type==='states') { const rows=this.choices(dataset);return rows.length ? `${rows.filter(row=>row.payload.active===true).length} / ${rows.length}` : '—'; }
      const row=this.choice(dataset);
      const precision=dataset.type==='predictions' ? 1 : {temperature:1,dissolved_oxygen:2,turbidity:2,ph:2,flow:1,level:2}[row?.parameter] ?? 3;
      return this.value(row,precision);
    },
    summaryUnit(dataset) { return dataset.type==='states' ? 'active overrides' : dataset.type==='discharges' ? 'notices in period' : this.unit(this.choice(dataset)?.unit); },
    choiceStatus(dataset) {
      if(dataset.type==='states') return 'Checked ' + this.stamp(this.status(dataset).last_success_at);
      if(dataset.type==='discharges') { const row=this.snapshot(dataset).latest;return row ? 'Latest source notice · '+this.observationStamp(row) : 'No notices retained'; }
      const row=this.choice(dataset);
      return row ? `${dataset.type==='laboratory' ? 'Sampled' : 'Latest'} · ${this.observationStamp(row)}` : 'No reading';
    },
    metricContext(dataset) {
      const row=this.choice(dataset);
      if(dataset.type==='measurements') return `${this.locationName(row?.location_id)} · ${row?.kind==='derived_sensor' ? 'EPA estimate · preliminary' : this.label(row?.status).toLowerCase()}`;
      if(dataset.type==='predictions') return 'CRWA model ' + (row?.payload.model_version || 'version unavailable');
      return '';
    },
    filters() { return {...(this.reach ? {reach:this.reach} : {}),...(this.location ? {location:this.location} : {})}; },
    range() { return {from:this.rangeStart,to:this.rangeEnd}; },
    setRange() {
      if (this.days==='custom') {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(this.fromDate) || !/^\d{4}-\d{2}-\d{2}$/.test(this.toDate)) throw new Error('Choose start and end dates.');
        const end = new Date(this.toDate+'T12:00:00Z'); end.setUTCDate(end.getUTCDate()+1);
        this.rangeStart = this.fromDate; this.rangeEnd = end.toISOString().slice(0,10);
        const duration = (new Date(this.rangeEnd)-new Date(this.rangeStart))/86400000;
        if (duration<1 || duration>365) throw new Error('Choose a period of 1–365 days.');
      } else {
        const now = Date.now();
        this.rangeStart = new Date(now-Number(this.days)*86400000).toISOString(); this.rangeEnd = new Date(now).toISOString();
      }
    },
    viewUrl(view = this.view) {
      const query = new URLSearchParams({view});
      if(this.periodExplicit || this.days!=='30')query.set('days',this.days);
      Object.entries({reach:this.reach,location:this.location,presentation:this.recordPresentation,type:this.recordType,source:this.recordSource,parameter:this.recordParameter,unit:this.recordUnit,method:this.recordMethod}).forEach(([key,value])=>{if(value)query.set(key,value);});
      if (this.days==='custom') { query.set('from',this.fromDate); query.set('to',this.toDate); }
      return '/water/charles?' + query;
    },
    syncUrl() { history.replaceState(null,'',this.viewUrl()); },
    async refreshReadings() {
      this.loading=true;
      try { this.data=await this.get('/metrics'); this.buildMetricCards(); this.loading=false; await this.$nextTick(); await this.refresh(); }
      catch(error) { this.error=error.message; }
      finally { this.loading=false; }
    },
    async refresh() {
      this.error = '';
      try { this.setRange(); } catch(error) { this.error=error.message; return; }
      this.syncUrl();
      if (this.view==='metrics') await Promise.all([this.loadCharts(),this.loadSignals()]);
      else if (this.view==='records') await this.loadRecords();
      else if (this.view==='map') { await this.$nextTick(); this.initMap(); this.updateMarkers(); }
    },
    async changePeriod() {
      this.periodExplicit=true;
      if(this.days==='custom') {
        const local=value=>new Date(value).toLocaleDateString('en-CA',{timeZone:'America/New_York'});
        this.fromDate=local(this.rangeStart); this.toDate=local(this.rangeEnd);
        return;
      }
      await this.refresh();
    },
    async selectReach() { this.location=''; await this.refresh(); },
    async selectLocation() { await this.refresh(); this.focusLocation(); },
    async changeView(view) { this.view=view; this.mapFilterOpen=false; this.mobileListOpen=false; await this.$nextTick(); await this.refresh(); if(view==='map') map?.resize(); },
    async loadCharts() {
      this.metricCards.forEach(dataset=>{
        const choices=this.choices(dataset);
        if(!choices.some(row=>row.external_id===dataset.choice)) dataset.choice=choices[0]?.external_id || '';
      });
      // A small worker pool avoids opening eight concurrent DB-heavy requests.
      const queue = this.metricGroups().flatMap(group=>group.datasets);
      await Promise.all(Array.from({length:3},async()=>{ while(queue.length) await this.loadChart(queue.shift()); }));
    },
    async loadChart(dataset) {
      const request = ++dataset.request;
      dataset.loading=true; dataset.error=''; dataset.result=null;
      const choices = this.choices(dataset);
      if (!choices.some(row=>row.external_id===dataset.choice)) dataset.choice=choices[0]?.external_id || '';
      const selected = this.choice(dataset);
      if (dataset.type==='states') { dataset.loading=false; return; }
      if (['measurements','predictions','laboratory'].includes(dataset.type) && !selected) { dataset.loading=false; return; }
      try {
        const params = {...this.historyRange(dataset),...this.filters(),source:selected?.source_slug || dataset.source,presentation:'observations'};
        if(dataset.type==='discharges') params.aggregation=(new Date(this.rangeEnd)-new Date(this.rangeStart))/86400000>60 ? 'month' : 'day';
        if(selected && ['measurements','predictions','laboratory'].includes(dataset.type)) Object.assign(params,{location:selected.location_id,parameter:selected.parameter,unit:selected.unit,kind:selected.kind,...(selected.method ? {method:selected.method} : {}),...(selected.segment ? {segment:selected.segment} : {})});
        const result = await this.get('/trends',params);
        if(request!==dataset.request) return;
        dataset.result=result; await this.$nextTick(); this.drawChart(dataset);
      } catch(error) { if(request===dataset.request) dataset.error=error.message; }
      finally { if(request===dataset.request) dataset.loading=false; }
    },
    drawChart(dataset) { const node = document.getElementById('water-chart-'+dataset.id); if(node) window.muniWaterChart.draw(node,dataset.result,this.chartMode(dataset)); },
    async loadSignals() {
      const request=++this.signalsRequest;
      try {
        const result = await this.get('/signals',{...this.range(),...this.filters(),limit:5000});
        if(request!==this.signalsRequest)return;
        const groups = new Map();
        for(const signal of result.signals) {
          if(!['active','detected'].includes(signal.status)) continue;
          const key=[signal.kind,signal.payload.source_slug,signal.payload.selector?.location_id,signal.payload.selector?.parameter].join('/');
          const old=groups.get(key);
          if(!old || (signal.payload.window?.comparison_end || signal.generated_at) > (old.payload.window?.comparison_end || old.generated_at)) groups.set(key,signal);
        }
        this.signals=[...groups.values()].slice(0,4);
      } catch(error) { if(request===this.signalsRequest)this.error=error.message; }
    },
    signalTitle(row) { return this.label(row.kind)+(row.payload.selector?.parameter ? ' · '+this.label(row.payload.selector.parameter) : ''); },
    signalWindow(row) { const w=row.payload.window || {}; return w.comparison_start ? `${w.comparison_start} → ${w.comparison_end}` : [w.start,w.end,w.detected_at].filter(Boolean).map(v=>this.stamp(v)).join(' → '); },
    async inspectSignal(row) { this.selectedSignal=row; await this.$nextTick(); this.$refs.signalDialog.showModal(); },
    async openRecords(dataset) {
      this.recordType=dataset.type; this.recordSource=this.choice(dataset)?.source_slug || dataset.source;
      const selected=['measurements','predictions','laboratory'].includes(dataset.type) ? this.choice(dataset) : null;
      this.recordParameter=selected?.parameter || ''; this.recordUnit=selected?.unit || ''; this.recordMethod='';
      if(selected) this.location=selected.location_id;
      if(selected && dataset.type==='laboratory') {
        this.days='custom';
        this.fromDate=this.toDate=selected.observed_date || new Date(selected.observed_at).toLocaleDateString('en-CA',{timeZone:'America/New_York'});
        this.recordMethod=selected.method || '';
      }
      await this.changeView('records');
    },
    async openSourceRecords(source) {
      const dataset = this.datasets.find(row=>row.source===source.source_slug);
      if (!dataset) return;
      this.reach=''; this.location=''; this.recordType=dataset.type; this.recordSource=this.choice(dataset)?.source_slug || dataset.source;
      this.recordParameter=''; this.recordUnit=''; this.recordMethod='';
      await this.changeView('records');
    },
    async openLocationRecords(place) {
      this.location=place.id; this.recordSource=''; this.recordParameter=''; this.recordUnit=''; this.recordMethod='';
      this.recordType=({laboratory:'laboratory',boathouse:'states',outfall:'discharges',reach:'predictions'})[place.kind] || 'measurements';
      await this.changeView('records');
    },
    recordKinds() { return {measurements:'sensor,derived_sensor,gauge',laboratory:'laboratory',predictions:'prediction',discharges:'discharge',states:'program_state'}[this.recordType]; },
    recordParams() {
      // Program states have retrieval times, but no invented observation times.
      return {presentation:this.recordPresentation,...(this.recordType==='states' ? {} : this.range()),...this.filters(),
        ...(this.recordSource ? {source:this.recordSource} : {}),...(this.recordParameter ? {parameter:this.recordParameter} : {}),
        ...(this.recordUnit ? {unit:this.recordUnit} : {}),...(this.recordMethod ? {method:this.recordMethod} : {}),
        ...(this.recordKinds() ? {kinds:this.recordKinds()} : {})};
    },
    async changeRecordType() { this.recordSource=''; this.recordParameter=''; this.recordUnit=''; this.recordMethod=''; await this.loadRecords(); },
    async loadRecords(offset=0) {
      const request=++this.recordsRequest; this.recordsLoading=true; this.records=[]; this.recordsNext=null; this.syncUrl();
      try {
        const result=await this.get(this.recordType==='changes' ? '/signals' : '/records',{...this.recordParams(),limit:50,offset});
        if(request!==this.recordsRequest)return;
        this.records=result.records || result.signals; this.recordsTotal=result.total; this.recordsOffset=offset; this.recordsNext=result.next_offset;
      } catch(error) { if(request===this.recordsRequest)this.error=error.message; }
      finally { if(request===this.recordsRequest)this.recordsLoading=false; }
    },
    async inspect(row) {
      const id=typeof row==='object' ? row.external_id : row;
      const params=typeof row==='object' && row.revision_id ? {revision:row.revision_id,...(row.revision_cutoff!=null ? {cutoff:row.revision_cutoff} : {})} : {};
      try { this.detail=await this.get('/evidence/'+encodeURIComponent(id),params); await this.$nextTick(); this.$refs.evidenceDialog.showModal(); } catch(error) {this.error=error.message;}
    },
    pointProvenance(point,dataset) {
      const versions=point.input_normalization_versions?.join(', ') || 'Not retained';
      return `${this.sourceName(dataset.result?.source_slug || dataset.source)} · Policy: ${point.policy_version || 'Not supplied'} · Revision cutoff: ${point.revision_cutoff ?? 'Not supplied'} · Input normalization: ${versions}`;
    },
    async downloadCsv() {
      this.exporting=true;
      try {
        const params={...this.recordParams(),limit:5000}; let cursor='start',cutoff=null; const chunks=[];
        do {
          const response=await fetch('/api/water/charles/export.csv?'+new URLSearchParams({...params,cursor}));
          if(!response.ok)throw new Error('CSV export failed.');
          const revision=response.headers.get('X-Revision-Cutoff');
          if(revision==null || (cutoff!==null && revision!==cutoff))throw new Error('Export snapshot could not be verified. Please retry.');
          cutoff=revision;
          const text=await response.text(); chunks.push(chunks.length===0 ? text : text.slice(text.indexOf('\n')+1));
          cursor=response.headers.get('X-Next-Cursor') || null;
          if(!cursor && response.headers.get('X-Next-Offset'))throw new Error('Export pagination is incomplete. Please retry.');
        } while(cursor!==null);
        const url=URL.createObjectURL(new Blob(chunks,{type:'text/csv;charset=utf-8'}));
        const link=document.createElement('a'); link.href=url; link.download='charles-water-records.csv'; document.body.append(link); link.click(); link.remove(); URL.revokeObjectURL(url);
      } catch(error) {this.error=error.message;} finally {this.exporting=false;}
    },
    mapRows() { return this.sortedLocations(); },
    selectedPlace() { return this.data.locations?.find(row=>row.id===this.location); },
    locationKind(place) { return ({laboratory:'Sampling station',boathouse:'Boathouse',gauge:'Upstream gauge',sensor:'Buoy',outfall:'Outfall',reach:'Boating reach'})[place?.kind] || this.label(place?.kind); },
    locationReadings(id) {
      const canonical=(this.data.metrics || []).map(metric=>metric.primary).filter(Boolean);
      return (canonical.length ? canonical : this.data.latest || []).filter(row=>row.location_id===id);
    },
    async selectMapLocation(id) {
      this.location=id; this.mobileListOpen=false; this.mapFilterOpen=false; this.syncUrl(); this.focusLocation();
      await this.$nextTick();
      this.$refs.mapListRows?.querySelector('[aria-pressed="true"]')?.scrollIntoView({block:'nearest'});
    },
    clearMapSelection() { this.location=''; this.syncUrl(); this.updateMarkers(); },
    hoverMapLocation(id) { this.hoveredLocation=id; this.updateMarkers(); },
    async toggleMobileList() { this.mobileListOpen=!this.mobileListOpen; if(this.mobileListOpen)this.clearMapSelection(); await this.$nextTick(); map?.resize(); },
    focusLocation() {
      const place=this.selectedPlace();
      if(place?.geometry?.type==='Point') {
        const mobile=window.matchMedia('(max-width: 639px)').matches;
        map?.flyTo({center:place.geometry.coordinates,zoom:14,offset:mobile ? [0,-100] : [-Math.min(190,map.getContainer().clientWidth/4),0]});
      }
      this.updateMarkers();
    },
    updateMarkers() { document.querySelectorAll('#water-map [data-water-location]').forEach(button=>{const loc=this.data.locations.find(row=>row.id===button.dataset.waterLocation); button.hidden=!!this.reach && loc?.reach_id!==this.reach; button.setAttribute('aria-pressed',String(loc?.id===this.location));button.classList.toggle('is-hovered',loc?.id===this.hoveredLocation);}); },
    async retryMap() { map?.remove(); map=null; await this.initMap(); },
    async initMap() {
      if(map)return;
      this.mapError='';
      if(typeof maplibregl==='undefined'){this.mapError='Map unavailable.';return;}
      const style=window.muniShell({}).mapStyle(); if(!style){this.mapError='Basemap unavailable.';return;}
      map=new maplibregl.Map({container:'water-map',style,center:[-71.118,42.362],zoom:12.2}); map.addControl(new maplibregl.NavigationControl());
      map.on('load',async()=>{
        try {
          const geometry=await this.get('/geojson'); map.addSource('water',{type:'geojson',data:geometry});
          map.addLayer({id:'water-area',type:'fill',source:'water',filter:['==',['geometry-type'],'Polygon'],paint:{'fill-color':'#3b8d83','fill-opacity':.25}});
          for(const feature of geometry.features.filter(row=>row.geometry.type==='Point')) {
            const button=document.createElement('button');button.type='button';
            button.className='water-marker';button.title=feature.properties.name;button.dataset.waterLocation=feature.id;
            button.addEventListener('click',()=>this.selectMapLocation(feature.id));
            button.addEventListener('mouseenter',()=>this.hoverMapLocation(feature.id));
            button.addEventListener('mouseleave',()=>this.hoverMapLocation(null));
            new maplibregl.Marker({element:button}).setLngLat(feature.geometry.coordinates).addTo(map); button.setAttribute('aria-label',feature.properties.name);
          }
          this.focusLocation();
        } catch(error) {this.mapError='Map locations unavailable.';}
      });
    }
  };
};
