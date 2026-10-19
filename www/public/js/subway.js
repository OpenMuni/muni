(function (root) {
  'use strict';
  const routes = ['Red', 'Orange', 'Blue', 'Green-B', 'Green-C', 'Green-D', 'Green-E', 'Mattapan'];
  const colors = {Red:'#da291c',Orange:'#ed8b00',Blue:'#003da5',Mattapan:'#da291c',
    'Green-B':'#00843d','Green-C':'#00843d','Green-D':'#00843d','Green-E':'#00843d'};
  const MAX_AGE_MS = 45000;

  function fresh(iso, now) {
    const age = now - Date.parse(iso);
    return Number.isFinite(age) && age >= 0 && age <= MAX_AGE_MS;
  }

  function duePredictions(rows, fetchedAt, now, notified) {
    if (!fresh(fetchedAt, now)) return [];
    return rows.filter(row => {
      const at = Date.parse(row.arrival_time || row.departure_time);
      return row.id && !['CANCELLED','SKIPPED'].includes(row.schedule_relationship) &&
        !notified.has(row.id) && (!row.updated_at || fresh(row.updated_at, now)) &&
        Number.isFinite(at) && at >= now && at - now <= 180000;
    });
  }

  function muniSubway() {
    let map = null;
    let stationMarkers = [];
    let vehicleMarkers = [];
    let timer = null;
    let audioContext = null;
    const notified = new Set();
    return {
      routes, route:'', stations:[], vehicles:[], predictions:[], alerts:[], selectedStation:'',
      homeStation:localStorage.getItem('muni-subway-home') || '',
      chimeEnabled:false, notificationsEnabled:false,
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
        await Promise.all([this.loadVehicles(), this.loadAlerts(), this.loadPredictions(), this.loadHomeNotifications()]);
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
          this.notifyArrivals(result.data, result.fetched_at, station);
        } catch (_) { if (station === this.selectedStation) { this.predictions = []; this.predictionsFetchedAt = ''; this.predictionsError = 'Arrivals unavailable.'; } }
      },
      selectStation() { this.predictions = []; this.predictionsFetchedAt = ''; this.loadPredictions(); this.renderMap(); },
      setHomeStation() { this.homeStation = this.selectedStation; localStorage.setItem('muni-subway-home', this.homeStation); },
      toggleChime() {
        this.chimeEnabled = !this.chimeEnabled;
        if (this.chimeEnabled) {
          const AudioContext = root.AudioContext || root.webkitAudioContext;
          if (AudioContext) { audioContext ||= new AudioContext(); audioContext.resume(); }
        }
      },
      async enableNotifications() {
        if (!('Notification' in root)) return;
        const permission = await root.Notification.requestPermission();
        this.notificationsEnabled = permission === 'granted';
      },
      async loadHomeNotifications() {
        if (!this.homeStation || this.homeStation === this.selectedStation ||
            (!this.notificationsEnabled && !this.chimeEnabled)) return;
        try {
          const result = await this.get('/predictions/' + encodeURIComponent(this.homeStation));
          this.notifyArrivals(result.data, result.fetched_at, this.homeStation);
        } catch (_) { /* An unavailable response cannot trigger a notification. */ }
      },
      notifyArrivals(rows = this.predictions, fetchedAt = this.predictionsFetchedAt, stationId = this.selectedStation) {
        if (!this.homeStation || stationId !== this.homeStation) return;
        if (!this.notificationsEnabled && !this.chimeEnabled) return;
        for (const row of duePredictions(rows, fetchedAt, Date.now(), notified)) {
          notified.add(row.id);
          const station = this.stations.find(s => s.id === this.homeStation);
          if (this.notificationsEnabled && root.Notification.permission === 'granted') {
            new root.Notification((station?.name || 'Home station') + ' train arriving soon',
              {body: row.route + ' train expected within 3 minutes'});
          }
          if (this.chimeEnabled) this.playChime();
        }
      },
      playChime() {
        if (!audioContext) return;
        const oscillator = audioContext.createOscillator();
        const gain = audioContext.createGain();
        oscillator.frequency.value = 660; gain.gain.value = 0.05;
        oscillator.connect(gain); gain.connect(audioContext.destination);
        oscillator.start(); oscillator.stop(audioContext.currentTime + 0.15);
      },
      filteredStations() { return this.stations.filter(s => !this.route || s.routes.includes(this.route)); },
      visibleVehicles() { return this.vehicles.filter(v => (!this.route || v.route === this.route) &&
        fresh(v.updated_at, Date.now())); },
      visibleAlerts() { return this.alerts.filter(a => !this.route || a.routes.includes(this.route)); },
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
        for (const station of this.filteredStations()) {
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
  if (typeof module !== 'undefined') module.exports = {fresh, duePredictions, muniSubway};
})(typeof window === 'undefined' ? globalThis : window);
