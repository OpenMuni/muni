(function (root) {
  'use strict';
  const colors = {Red:'#da291c',Orange:'#ed8b00',Blue:'#003da5',Mattapan:'#da291c',
    'Green-B':'#00843d','Green-C':'#00843d','Green-D':'#00843d','Green-E':'#00843d'};
  const MAX_AGE_MS = 45000;
  const trainIcon = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="3" width="14" height="15" rx="4"/><path d="M5 11h14M9 3v8M15 3v8M8 18l-2 3M16 18l2 3M8 21h8"/><circle cx="9" cy="15" r="1"/><circle cx="15" cy="15" r="1"/></svg>';

  function coordinatesValid(row) {
    return typeof row.latitude === 'number' && typeof row.longitude === 'number' &&
      Number.isFinite(row.latitude) && Number.isFinite(row.longitude) &&
      Math.abs(row.latitude) <= 90 && Math.abs(row.longitude) <= 180;
  }

  // MBTA shapes use Google's encoded polyline format at precision 5.
  function decodePolyline(encoded) {
    if (typeof encoded !== 'string') throw new Error('Invalid route geometry');
    let index = 0, latitude = 0, longitude = 0;
    const points = [];
    function delta() {
      let value = 0, shift = 0, byte;
      do {
        byte = encoded.charCodeAt(index++) - 63;
        if (!Number.isInteger(byte) || byte < 0 || byte > 63 || shift > 30) throw new Error('Invalid route geometry');
        value |= (byte & 31) << shift;
        shift += 5;
      } while (byte >= 32);
      return value & 1 ? ~(value >> 1) : value >> 1;
    }
    while (index < encoded.length) {
      latitude += delta(); longitude += delta();
      if (!coordinatesValid({latitude:latitude / 1e5, longitude:longitude / 1e5})) throw new Error('Invalid route geometry');
      points.push([longitude / 1e5, latitude / 1e5]);
    }
    if (points.length < 2) throw new Error('Invalid route geometry');
    return points;
  }

  function routeFeatures(shapes) {
    return {type:'FeatureCollection', features:shapes.filter(s => colors[s.route]).map(shape => ({
      type:'Feature', properties:{route:shape.route, color:colors[shape.route]},
      geometry:{type:'LineString', coordinates:decodePolyline(shape.polyline)}
    }))};
  }

  function fresh(iso, now) {
    const age = now - Date.parse(iso);
    return Number.isFinite(age) && age >= 0 && age <= MAX_AGE_MS;
  }

  function muniSubway() {
    let map = null;
    const stationMarkers = new Map();
    const vehicleMarkers = new Map();
    let mapReady = false;
    let routeData = {type:'FeatureCollection', features:[]};
    let timer = null;
    return {
      stations:[], vehicles:[], predictions:[], alerts:[], selectedStation:'', view:'arrivals', listOpen:false,
      homeStation:localStorage.getItem('muni-subway-home') || '',
      stationsFetchedAt:'', vehiclesFetchedAt:'', predictionsFetchedAt:'', alertsFetchedAt:'',
      stationsError:'', vehiclesError:'', predictionsError:'', alertsError:'', shapesError:'', mapError:'',
      async init() {
        this.selectedStation = this.homeStation;
        await this.loadStations();
        await this.$nextTick();
        await this.initMap();
        await Promise.all([this.loadShapes(), this.refresh()]);
        timer = setInterval(() => this.refresh(), 15000);
      },
      destroy() { if (timer) clearInterval(timer); mapReady = false; if (map) map.remove(); map = null; },
      async get(path) {
        const response = await fetch('/api/mobility/subway' + path);
        const body = await response.json();
        if (!response.ok) throw new Error(body.error || 'MBTA data unavailable');
        return body;
      },
      async loadStations() {
        try {
          const result = await this.get('/stations');
          this.stations = result.data; this.stationsFetchedAt = result.fetched_at; this.stationsError = '';
          if (!this.stations.some(s => s.id === this.selectedStation)) this.selectedStation = '';
          this.renderMap();
        } catch (_) { this.stations = []; this.stationsFetchedAt = ''; this.stationsError = 'Stations unavailable. Retry by reloading.'; }
      },
      async refresh() {
        await Promise.all([this.loadVehicles(), this.loadAlerts(), this.loadPredictions()]);
      },
      async loadShapes() {
        try {
          const result = await this.get('/shapes');
          routeData = routeFeatures(result.data);
          this.shapesError = routeData.features.length ? '' : 'Route lines unavailable.';
          this.renderRoutes();
        } catch (_) { this.shapesError = 'Route lines unavailable.'; }
      },
      async loadVehicles() {
        try {
          const result = await this.get('/vehicles');
          this.vehicles = result.data; this.vehiclesFetchedAt = result.fetched_at; this.vehiclesError = '';
          this.renderMap();
        } catch (_) { this.vehicles = []; this.vehiclesFetchedAt = ''; this.vehiclesError = 'Live vehicles unavailable.'; this.renderMap(); }
      },
      async loadAlerts() {
        try {
          const result = await this.get('/alerts');
          this.alerts = result.data; this.alertsFetchedAt = result.fetched_at; this.alertsError = '';
        } catch (_) { this.alerts = []; this.alertsFetchedAt = ''; this.alertsError = 'Service alerts unavailable.'; }
      },
      async loadPredictions() {
        if (!this.selectedStation) { this.predictions = []; this.predictionsFetchedAt = ''; return; }
        const station = this.selectedStation;
        try {
          const result = await this.get('/predictions/' + encodeURIComponent(station));
          if (station !== this.selectedStation) return;
          this.predictions = result.data.filter(row => {
            const at = Date.parse(row.arrival_time || row.departure_time);
            return Number.isFinite(at) && at >= Date.now() - 60000 &&
              !['CANCELLED','SKIPPED'].includes(row.schedule_relationship);
          }).sort((a,b) => Date.parse(a.arrival_time || a.departure_time) -
                           Date.parse(b.arrival_time || b.departure_time)).slice(0, 8);
          this.predictionsFetchedAt = result.fetched_at; this.predictionsError = '';
        } catch (_) { if (station === this.selectedStation) { this.predictions = []; this.predictionsFetchedAt = ''; this.predictionsError = 'Arrivals unavailable.'; } }
      },
      selectView(view) { this.view = view; this.listOpen = true; },
      selectStation() { this.selectView('arrivals'); this.predictions = []; this.predictionsFetchedAt = ''; this.loadPredictions(); this.renderMap(); },
      setHomeStation() { this.homeStation = this.selectedStation; localStorage.setItem('muni-subway-home', this.homeStation); },
      visibleVehicles() { return this.vehicles.filter(v => fresh(v.updated_at, Date.now())); },
      routeLabel(value) { return value?.replace('Green-', 'Green ') || 'Train'; },
      arrivalLabel(row) {
        const at = Date.parse(row.arrival_time || row.departure_time);
        if (!Number.isFinite(at)) return row.status || 'Time unavailable';
        const minutes = Math.max(0, Math.ceil((at - Date.now()) / 60000));
        return minutes === 0 ? 'Now' : minutes + ' min';
      },
      stamp(value) { return value ? new Date(value).toLocaleTimeString([], {hour:'numeric',minute:'2-digit',second:'2-digit'}) : ''; },
      async initMap() {
        try { await root.MUNI_MAP_READY; } catch (_) { this.mapError = 'Map unavailable.'; return; }
        const style = root.muniShell({}).mapStyle();
        if (!style) { this.mapError = 'Basemap unavailable.'; return; }
        map = new root.maplibregl.Map({container:'subway-map',style,center:[-71.06,42.35],zoom:10.7});
        map.addControl(new root.maplibregl.NavigationControl());
        map.on('load', () => {
          mapReady = true;
          const coordinates = this.stations.filter(coordinatesValid);
          if (coordinates.length) {
            const lons = coordinates.map(s => Number(s.longitude));
            const lats = coordinates.map(s => Number(s.latitude));
            map.fitBounds([[Math.min(...lons),Math.min(...lats)], [Math.max(...lons),Math.max(...lats)]],
              {padding:35,duration:0});
          }
          this.renderMap();
          this.renderRoutes();
        });
      },
      renderRoutes() {
        if (!map || !mapReady) return;
        const source = map.getSource('subway-routes');
        if (source) { source.setData(routeData); return; }
        map.addSource('subway-routes', {type:'geojson', data:routeData});
        const layout = {'line-cap':'round', 'line-join':'round'};
        map.addLayer({id:'subway-route-casing', type:'line', source:'subway-routes', layout,
          paint:{'line-color':'#fff', 'line-width':['interpolate',['linear'],['zoom'],10,6,14,10]}});
        map.addLayer({id:'subway-route-lines', type:'line', source:'subway-routes', layout,
          paint:{'line-color':['get','color'], 'line-width':['interpolate',['linear'],['zoom'],10,3,14,6]}});
      },
      renderMap() {
        if (!map) return;
        const stations = this.stations.filter(coordinatesValid);
        const vehicles = this.visibleVehicles().filter(coordinatesValid);
        for (const [markers, rows] of [[stationMarkers, stations], [vehicleMarkers, vehicles]]) {
          const ids = new Set(rows.map(row => row.id));
          for (const [id, marker] of markers) {
            if (!ids.has(id)) { marker.remove(); markers.delete(id); }
          }
        }
        for (const station of stations) {
          if (!stationMarkers.has(station.id)) {
            const element = document.createElement('button'); element.type = 'button';
            element.className = 'subway-marker';
            const label = document.createElement('span'); label.className = 'subway-marker__label';
            element.appendChild(label);
            element.addEventListener('click', () => { this.selectedStation = station.id; this.selectStation(); });
            stationMarkers.set(station.id, new root.maplibregl.Marker({element}).setLngLat([station.longitude,station.latitude]).addTo(map));
          }
          const element = stationMarkers.get(station.id).getElement();
          const selected = station.id === this.selectedStation;
          const transfer = new Set(station.routes.map(route => route.split('-')[0])).size > 1;
          element.classList.toggle('subway-marker--selected', selected);
          element.classList.toggle('subway-marker--transfer', transfer);
          element.firstChild.textContent = station.name;
          element.setAttribute('aria-pressed', String(selected));
          element.setAttribute('aria-label', station.name + ' station · ' + station.routes.map(route => this.routeLabel(route)).join(', '));
        }
        for (const vehicle of vehicles) {
          if (!vehicleMarkers.has(vehicle.id)) {
            const element = document.createElement('div'); element.className = 'subway-train';
            element.tabIndex = 0; element.setAttribute('role', 'img');
            element.innerHTML = trainIcon + '<span class="subway-marker__label"></span>';
            vehicleMarkers.set(vehicle.id, new root.maplibregl.Marker({element}).setLngLat([vehicle.longitude,vehicle.latitude]).addTo(map));
          }
          const marker = vehicleMarkers.get(vehicle.id);
          const element = marker.getElement();
          const status = {STOPPED_AT:'At station', INCOMING_AT:'Approaching station', IN_TRANSIT_TO:'In transit'}[vehicle.current_status] || 'Location reported';
          const label = this.routeLabel(vehicle.route) + ' train ' + vehicle.id + ' · ' + status + ' · Updated ' + this.stamp(vehicle.updated_at);
          element.style.setProperty('--train-color', colors[vehicle.route] || '#35465a');
          element.querySelector('.subway-marker__label').textContent = label;
          element.setAttribute('aria-label', label);
          marker.setLngLat([vehicle.longitude,vehicle.latitude]);
        }
      }
    };
  }

  root.muniSubway = muniSubway;
  if (typeof module !== 'undefined') module.exports = {fresh, decodePolyline, routeFeatures, muniSubway};
})(typeof window === 'undefined' ? globalThis : window);
