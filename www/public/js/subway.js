(function (root) {
  'use strict';
  const colors = {Red:'#da291c',Orange:'#ed8b00',Blue:'#003da5',Mattapan:'#da291c',
    'Green-B':'#00843d','Green-C':'#00843d','Green-D':'#00843d','Green-E':'#00843d'};
  const MAX_AGE_MS = 45000;

  function fresh(iso, now) {
    const age = now - Date.parse(iso);
    return Number.isFinite(age) && age >= 0 && age <= MAX_AGE_MS;
  }

  function muniSubway() {
    let map = null;
    let stationMarkers = [];
    let vehicleMarkers = [];
    let timer = null;
    return {
      stations:[], vehicles:[], predictions:[], alerts:[], selectedStation:'', view:'arrivals', listOpen:false,
      homeStation:localStorage.getItem('muni-subway-home') || '',
      stationsFetchedAt:'', vehiclesFetchedAt:'', predictionsFetchedAt:'', alertsFetchedAt:'',
      stationsError:'', vehiclesError:'', predictionsError:'', alertsError:'', mapError:'',
      async init() {
        this.selectedStation = this.homeStation;
        await this.loadStations();
        await this.$nextTick();
        await this.initMap();
        await this.refresh();
        timer = setInterval(() => this.refresh(), 15000);
      },
      destroy() { if (timer) clearInterval(timer); if (map) map.remove(); },
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
          const coordinates = this.stations.filter(s => Number.isFinite(Number(s.latitude)) &&
            Number.isFinite(Number(s.longitude)));
          if (coordinates.length) {
            const lons = coordinates.map(s => Number(s.longitude));
            const lats = coordinates.map(s => Number(s.latitude));
            map.fitBounds([[Math.min(...lons),Math.min(...lats)], [Math.max(...lons),Math.max(...lats)]],
              {padding:35,duration:0});
          }
          this.renderMap();
        });
      },
      renderMap() {
        if (!map) return;
        stationMarkers.forEach(marker => marker.remove()); stationMarkers = [];
        vehicleMarkers.forEach(marker => marker.remove()); vehicleMarkers = [];
        for (const station of this.stations) {
          if (!Number.isFinite(Number(station.latitude)) || !Number.isFinite(Number(station.longitude))) continue;
          const marker = document.createElement('button'); marker.type = 'button';
          marker.className = 'subway-marker' + (station.id === this.selectedStation ? ' subway-marker--selected' : '');
          marker.style.background = colors[station.routes[0]] || '#35465a';
          marker.title = station.name; marker.setAttribute('aria-label', station.name + ' station');
          marker.addEventListener('click', () => { this.selectedStation = station.id; this.selectStation(); });
          stationMarkers.push(new root.maplibregl.Marker({element:marker}).setLngLat([station.longitude,station.latitude]).addTo(map));
        }
        for (const vehicle of this.visibleVehicles()) {
          const marker = document.createElement('div'); marker.className = 'subway-marker subway-marker--vehicle';
          marker.style.background = colors[vehicle.route]; marker.title = vehicle.route + ' train';
          marker.setAttribute('aria-label', marker.title);
          vehicleMarkers.push(new root.maplibregl.Marker({element:marker}).setLngLat([vehicle.longitude,vehicle.latitude]).addTo(map));
        }
      }
    };
  }

  root.muniSubway = muniSubway;
  if (typeof module !== 'undefined') module.exports = {fresh, muniSubway};
})(typeof window === 'undefined' ? globalThis : window);
