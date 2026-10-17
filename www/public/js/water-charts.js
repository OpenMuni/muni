// The same bar/line treatment as Trends, with explicit missing intervals.
window.muniWaterChart = {
  calendarDate(value) {
    const text=String(value || '');
    return /^\d{4}-\d{2}-\d{2}$/.test(text) ? text : Number.isFinite(Date.parse(text)) ? new Date(text).toLocaleDateString('en-CA',{timeZone:'America/New_York'}) : '';
  },
  dateLabel(value, aggregation) {
    const date=this.calendarDate(value);
    return aggregation==='month' ? date.slice(5,7)+'/'+date.slice(2,4) : date.slice(5).replace('-', '/') + '/' + date.slice(2,4);
  },
  model(series, zeroBaseline=true, range={}) {
    const values = series.flatMap(s => s.points).map(p => p.value).filter(v => v != null);
    const domain=zeroBaseline || !values.length ? [0,...values] : values;
    const low = Math.min(...domain), high = Math.max(...domain);
    const span = high - low || 1;
    const y = value => 170 - ((value - low) / span) * 140;
    const time=point=>Date.parse(range.calendarDates ? this.calendarDate(point.observed_date || point.observed_at || point.date) : point.time_precision==='date' ? (point.observed_date || point.date || '') : (point.observed_at || point.date || point.observed_date || ''));
    const times=series.flatMap(s=>s.points.map(time)).filter(Number.isFinite);
    const bound=value=>Date.parse(range.calendarDates ? this.calendarDate(value) : value || '');
    const rangeStart=bound(range.from),rangeEnd=bound(range.to);
    const first=Number.isFinite(rangeStart) ? rangeStart : times.length ? Math.min(...times) : null;
    const last=Number.isFinite(rangeEnd) ? rangeEnd : times.length ? Math.max(...times) : null;
    const length = Math.max(1, ...series.map(s => s.points.length));
    const step = 420 / length;
    return {low, high: low + span, zero: y(0), series: series.map((s, index) => {
      let path = '', previous = false, previousTime = null;
      const bars = [];
      s.points.forEach((point, i) => {
        if (point.value == null) { previous = false; return; }
        const stamp=time(point);
        const x = first!==null && last>first && Number.isFinite(stamp) ? 50 + ((stamp-first)/(last-first))*420 : 50 + step * (i + .5);
        const yy = y(point.value);
        if(s.kind==='prediction' && previousTime!==null && stamp-previousTime>3600000)previous=false;
        previousTime=Number.isFinite(stamp) ? stamp : null;
        path += `${previous ? 'L' : 'M'}${x},${yy} `;
        previous = true;
        bars.push({x: x - step * .36 + index * step * .72 / series.length, y: Math.min(yy, y(0)),
          width: Math.max(.4, step * .72 / series.length), height: Math.abs(yy - y(0)), pointX:x, pointY:yy, point});
      });
      return {...s, bars, path};
    })};
  },
  draw(container, result, mode='both') {
    container.replaceChildren();
    if (!result?.series?.some(s => s.points.some(p => p.value != null))) return;
    const discreteRange=result.aggregation==='none' ? {...result,calendarDates:mode==='points'} : {};
    const model = this.model(result.series,!['line','points'].includes(mode),discreteRange);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 490 205');
    svg.setAttribute('aria-hidden', 'true');
    const add = (tag, attrs, text) => {
      const node = document.createElementNS(ns, tag);
      Object.entries(attrs).forEach(([name, value]) => node.setAttribute(name, value));
      if (text != null) node.textContent = text;
      svg.append(node); return node;
    };
    const ticks=[...new Set([0,.5,1].map(f=>{
      const value=model.low + f * (model.high-model.low);
      return result.statistic==='count' ? Math.round(value) : value;
    }))];
    ticks.forEach(value => {
      const y = 170 - (value-model.low) / (model.high-model.low) * 140;
      add('line', {x1:50, x2:470, y1:y, y2:y, class:'water-chart-grid'});
      add('text', {x:44,y:y+4,'text-anchor':'end'}, value.toLocaleString('en-US',{maximumFractionDigits:result.statistic==='count' ? 0 : 2}));
    });
    const colors = ['#246b58','#466fa2','#9d6a28','#8059a0'];
    model.series.forEach((series, index) => {
      const color = colors[index % colors.length];
      if(!['line','points'].includes(mode)) series.bars.forEach(bar => {
        const node = add('rect',{x:bar.x,y:bar.y,width:bar.width,height:bar.height,fill:color,opacity:bar.point.partial ? .18 : .3});
        const title = document.createElementNS(ns,'title');
        title.textContent = `${bar.point.date}: ${bar.point.value} ${series.unit}${bar.point.partial ? ' · partial day' : ''}`;
        node.append(title);
      });
      if(!['bars','points'].includes(mode)) add('path',{d:series.path,fill:'none',stroke:color,'stroke-width':2,'stroke-dasharray':series.kind === 'prediction' ? '5 3' : 'none'});
      // A single observation still has a visible marker.
      if(mode!=='bars') series.bars.forEach(bar => {
        const dot=add('circle',{cx:bar.pointX,cy:bar.pointY,r:mode==='points' ? 3.4 : 1.7,fill:color});
        const title=document.createElementNS(ns,'title');
        const stamp=bar.point.time_precision==='date' ? (bar.point.observed_date || bar.point.date) : (bar.point.observed_at || bar.point.date);
        title.textContent=`${stamp}: ${bar.point.value} ${series.unit || ''}`;
        dot.append(title);
      });
    });
    const points = result.series[0].points;
    const short = value => this.dateLabel(value,result.aggregation);
    if (points.length) {
      add('text',{x:50,y:195},short(discreteRange.from || points[0].observed_date || points[0].date || points[0].observed_at));
      add('text',{x:470,y:195,'text-anchor':'end'},short(discreteRange.to || points[points.length-1].observed_date || points[points.length-1].date || points[points.length-1].observed_at));
    }
    container.append(svg);
  }
};
