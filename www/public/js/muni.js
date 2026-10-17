const MUNI_DOT_COLORS = {
  open:         '#ff7a00',
  acknowledged: '#2563eb',
  stale:        '#7c3aed',
  pending:      '#d4ad00',
  closed:       '#14ae5c',
  archived:     '#8a8f98',
  fatal:        '#991b1b',
  injury:       '#ea580c',
  no_injury:    '#6b7280',
  tree:         '#15803d',
  retired:      '#78716c',
  stump:        '#a16207',
  planting:     '#16a34a',
  park:         '#2f8f46',
  parking_paid: '#1e489f',
  parking_outside: '#64748b',
  parking_unknown: '#d4ad00',
  police_log:   '#9b1c31',
  crime:        '#dc2626',
  dispatch_fire: '#ea580c',
  dispatch_police: '#2563eb',
  recent_crash: '#7f1d1d',
  '':           '#999999'
};

const MUNI_QUERY_LIMIT = window.MUNI_QUERY_LIMIT || 200;
const MUNI_DISPLAY = window.MUNI_DISPLAY || {};

const MUNI_CATEGORY_MAP = {
  service_requests: { accent: '#ff7a00', statusDots: true,  radius: 5, cluster: false, geoLimit: 5000 },
  safety:          { accent: '#9b1c31', statusDots: false, incidentDots: true, radius: 5, cluster: true },
  police:           { accent: '#9b1c31', statusDots: false, radius: 5, cluster: false },
  crime_reports:    { accent: '#dc2626', statusDots: false, radius: 5, cluster: true },
  dispatch_calls:   { accent: '#2563eb', statusDots: false, radius: 5, cluster: true },
  recent_crashes:   { accent: '#7f1d1d', statusDots: true,  radius: 6, cluster: true },
  permits:          { accent: '#6d4c9e', statusDots: true,  radius: 5, cluster: true },
  developments:     { accent: '#6d4c9e', statusDots: true,  radius: 5, cluster: true },
  crashes:          { accent: '#b91c1c', statusDots: true,  radius: 6, cluster: true },
  traffic_volume:   { accent: '#0f766e', statusDots: false, radius: 6, cluster: true },
  bicycle_counts:   { accent: '#16a34a', statusDots: false, radius: 5, cluster: true },
  pedestrian_counts: { accent: '#0891b2', statusDots: false, radius: 5, cluster: true },
  parking:         { accent: '#1e489f', statusDots: true,  radius: 5, cluster: false, polygon: true, geoLimit: 5000 },
  environment:     { accent: '#2f8f46', statusDots: true,  radius: 5, cluster: true, polygon: true, geoLimit: 5000 },
  trees:            { accent: '#15803d', statusDots: true,  radius: 5, cluster: true },
  parks:            { accent: '#2f8f46', statusDots: true,  radius: 5, cluster: false, polygon: true, geoLimit: 2000 },
  food_trucks:      { accent: '#0f766e', statusDots: false, radius: 6, cluster: true },
  events:           { accent: '#111111', statusDots: false, radius: 6, cluster: true },
  default:          { accent: '#525252', statusDots: false, radius: 5, cluster: true }
};

const MUNI_TITLE_FIELDS = MUNI_DISPLAY.title_fields || {};
const MUNI_SUBTITLE_FIELDS = MUNI_DISPLAY.subtitle_fields || {};
const MUNI_META_FIELDS = MUNI_DISPLAY.meta_fields || {};
const MUNI_PROP_LABELS = MUNI_DISPLAY.field_labels || {};
const MUNI_DEFAULT_TITLE_FIELDS = MUNI_DISPLAY.default_title_fields || [
  'case_type', 'name', 'permit_type', 'description',
  'incident_type', 'crime_category', 'crash_type', 'violation_description',
  'intersection', 'count_location', 'species_common', 'external_id'
];
const MUNI_DEFAULT_SUBTITLE_FIELDS = MUNI_DISPLAY.default_subtitle_fields || [
  'neighborhood', 'address', 'location_description', 'status', 'vehicle_class'
];

window.muniShell = function ({ hall, category }) {
  return {
    hall,
    category: String(category || ''),
    _switchToken: 0,
    rows: [],
    rowsLoading: false,
    halls: [],
    categories: [],
    facets: [],
    filters: {},
    filterOpen: false,
    selected: null,
    hoveredId: null,
    map: null,
    mapError: null,
    eventSource: null,
    categoryConfig: null,
    timeTick: 0,
    _geoRefreshTimer: null,
    _geoFitPending: false,
    _mapEventsBound: false,
    _boundMapLayers: new Set(),
    _pmtilesReady: false,
    streamsEnabled: Boolean(window.MUNI_STREAMS_ENABLED),
    geoFeatureCount: null,
    mobileListOpen: false,
    parkingLocationRequested: false,
    parkingLocationPending: false,
    parkingUserLocation: null,
    parkingLocationError: null,
    parkingDurationMinutes: 60,
    closedSubnavSection: null,

    async init() {
      const r = await fetch('/api/halls'); this.halls = await r.json();
      await this.loadCategories();
      if (this.category === 'recent_crashes') this.category = 'crashes';
      const current = this.categories.find(c => String(c.slug) === this.category);
      const firstEnabled = this.categories.find(c => !c.disabled);
      if (!current || current.disabled) {
        const pick = firstEnabled || this.categories[0];
        if (pick) this.category = String(pick.slug);
      }
      setInterval(() => { this.timeTick++; }, 30000);
      this.setCategory(this.category, true);
      window.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        if (this.filterOpen) {
          this.filterOpen = false;
          return;
        }
        const activeGroup = this.activeCategoryGroup();
        if (this.isSubnavOpen(activeGroup)) {
          this.closedSubnavSection = activeGroup.section;
          return;
        }
        this.selected = null;
      });
      window.addEventListener('resize', () => this.resizeMap());
      window.addEventListener('orientationchange', () => this.$nextTick(() => this.resizeMap()));
    },

    async loadCategories() {
      const c = await fetch('/api/categories?hall=' + encodeURIComponent(this.hall));
      this.categories = await c.json();
      this.categoryConfig = this.categories.find(x => String(x.slug) === this.category);
    },

    get defaultWidget() { return this.categoryConfig?.default_widget || 'map'; },
    get categoryTitle() { return this.categoryConfig?.title || this.category; },
    eventCategory() { return this.category === 'events'; },
    get groupedCategories() {
      const groups = [];
      (this.categories || []).forEach((cat) => {
        const section = cat.section || 'Other';
        let group = groups.find((entry) => entry.section === section);
        if (!group) {
          group = { section, categories: [] };
          groups.push(group);
        }
        group.categories.push(cat);
      });
      return groups;
    },
    sectionHasActiveCategory(group) {
      return (group?.categories || []).some((cat) => String(cat.slug) === this.category);
    },
    activeCategoryGroup() {
      return this.groupedCategories.find((group) => this.sectionHasActiveCategory(group)) || null;
    },
    activeSubnavItems() {
      const group = this.activeCategoryGroup();
      return this.hasNavSubitems(group) ? this.navItemsForGroup(group) : [];
    },
    subnavLayoutOpen() {
      return this.isSubnavOpen(this.activeCategoryGroup());
    },
    hasNavSubitems(group) {
      return this.navItemsForGroup(group).length > 1;
    },
    isSubnavOpen(group) {
      return this.hasNavSubitems(group) &&
        this.sectionHasActiveCategory(group) &&
        this.closedSubnavSection !== group.section;
    },
    primaryNavItem(group) {
      return this.navItemsForGroup(group)[0] || null;
    },
    navItemsForGroup(group) {
      const categories = group?.categories || [];
      if (group?.section === 'Safety') return this.safetyNavItems(categories);

      return categories.map((cat, index) => this.navItemForCategory(
        cat,
        categories.length > 1 && index === 0 ? 'All' : cat.title
      ));
    },
    safetyNavItems(categories) {
      const bySlug = Object.fromEntries(categories.map((cat) => [String(cat.slug), cat]));
      const items = [];
      if (bySlug.safety) items.push(this.navItemForCategory(bySlug.safety, 'All'));
      if (bySlug.police) items.push(this.navItemForCategory(bySlug.police, 'Police'));
      if (bySlug.dispatch_calls) {
        items.push(this.navItemForCategory(bySlug.dispatch_calls, 'Fire', {
          icon: 'flame',
          title: 'Fire dispatch',
          filters: { agency: 'Fire' }
        }));
      }
      ['crime_reports', 'dispatch_calls', 'crashes'].forEach((slug) => {
        if (bySlug[slug]) items.push(this.navItemForCategory(bySlug[slug], bySlug[slug].title));
      });
      return items;
    },
    navItemForCategory(cat, label, overrides = {}) {
      const filters = overrides.filters || {};
      return {
        key: `${cat.slug}:${Object.entries(filters).map(([key, value]) => `${key}=${value}`).join('&')}`,
        slug: String(cat.slug),
        label,
        title: overrides.title || cat.title,
        icon: overrides.icon || cat.icon,
        disabled: Boolean(cat.disabled),
        filters
      };
    },
    navItemActive(item) {
      if (!item || this.category !== String(item.slug)) return false;

      const expected = item.filters || {};
      const expectedKeys = Object.keys(expected);
      if (expectedKeys.length > 0) {
        return expectedKeys.every((key) => this.filters[key] === expected[key]);
      }

      return Object.entries(this.filters).every(([key, value]) => {
        if (!value) return true;
        if (key === 'open_now') return true;
        if (key === 'time_range') return value === this.defaultFilterValue(key);
        return false;
      });
    },
    selectNavItem(item) {
      if (!item || item.disabled) return;
      this.closedSubnavSection = null;
      this.setCategory(item.slug, false, item.filters || {});
    },
    togglePrimaryNav(group) {
      if (!group) return;
      if (this.hasNavSubitems(group) && this.sectionHasActiveCategory(group)) {
        this.closedSubnavSection = this.closedSubnavSection === group.section ? null : group.section;
        return;
      }
      this.closedSubnavSection = null;
      this.selectNavItem(this.primaryNavItem(group));
    },
    sectionIcon(section) {
      return {
        '311': 'rss',
        Safety: 'caution',
        Mobility: 'route',
        Parking: 'parking',
        'Housing & Development': 'buildings',
        'Food Trucks': 'truck',
        Events: 'calendar',
        Environment: 'leaf',
        'Money & Government': 'landmark'
      }[section] || 'dashboard';
    },
    get emptyMessage() {
      if (this.rowsLoading) return '';
      if (this.activeFilterCount > 0 || this.openNowActive) return 'No records match these filters.';
      return this.categoryConfig?.empty_message || 'No data yet for this category.';
    },
    get activeFilterCount() {
      return Object.entries(this.filters).filter(([key, value]) => {
        if (key === 'open_now') return false;
        if (key === 'time_field') return false;
        if (!value) return false;
        return value !== this.defaultFilterValue(key);
      }).length;
    },
    get showOpenNowToggle() { return this.category === 'food_trucks'; },
    get openNowActive() { return this.filters.open_now === '1'; },
    get mapEmptyMessage() {
      if (this.category === 'police') return 'No geocoded police locations for this filter.';
      return 'No mappable records for this view.';
    },

    queryParams() {
      const qs = new URLSearchParams({ hall: this.hall, limit: String(MUNI_QUERY_LIMIT) });
      Object.entries(this.filters).forEach(([k, v]) => { if (v) qs.set(k, v); });
      return qs;
    },

    geoQueryParams() {
      const theme = this.mapTheme();
      const qs = this.queryParams();
      if (theme.geoLimit) qs.set('limit', String(theme.geoLimit));
      return qs;
    },

    async setCategory(slug, initial = false, requestedFiltersOverride = null) {
      const next = this.categories.find(x => String(x.slug) === String(slug));
      if (!next || next.disabled) return;
      const requestedFilters = initial ? this.urlFilters() : (requestedFiltersOverride || {});

      const token = ++this._switchToken;
      this.category = String(slug);
      this.categoryConfig = next;
      this.filters = {};
      this.facets = [];
      this.filterOpen = false;
      this.rows = [];
      this.selected = null;
      this.hoveredId = null;
      this.mapError = null;
      this.geoFeatureCount = null;
      this.mobileListOpen = false;
      this._geoFitPending = true;
      if (this.category !== 'parking') this.clearParkingLocationLayer();

      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }

      try {
        if (this.defaultWidget !== 'map') this.clearMapLayers();

        await this.loadFacets();
        if (token !== this._switchToken) return;
        this.applyDefaultFilters();
        this.applyRequestedFilters(requestedFilters);
        await this.loadRows();
        if (token !== this._switchToken) return;

        if (this.defaultWidget === 'map') {
          await this.maybeInitMap();
          if (token !== this._switchToken) return;
          if (this.category === 'parking') this.maybeRequestParkingLocation();
        } else {
          this.clearMapLayers();
        }

        if (this.streamsEnabled) this.attachStream();
      } catch (e) {
        if (token !== this._switchToken) return;
        this.mapError = e?.message || 'Unable to load this view';
      } finally {
        if (!initial) this.$nextTick(() => this.focusActiveRail());
      }
    },

    async loadFacets() {
      try {
        const r = await fetch(`/api/category/${encodeURIComponent(this.category)}/facets?hall=${this.hall}`);
        this.facets = r.ok ? (await r.json()).filter(f => f.values.length > 0) : [];
      } catch (_) {
        this.facets = [];
      }
    },

    applyDefaultFilters() {
      const time = this.facets.find(f => f.name === 'time_range');
      if (time && !this.filters.time_range) this.filters.time_range = time.default || '7d';
    },

    urlFilters() {
      const params = new URLSearchParams(window.location.search);
      const filters = {};
      params.forEach((value, key) => {
        if (['hall', 'category'].includes(key)) return;
        if (value) filters[key] = value;
      });
      return filters;
    },

    applyRequestedFilters(requested) {
      Object.entries(requested || {}).forEach(([key, value]) => {
        if (key === 'open_now' && this.showOpenNowToggle && ['1', 'true', 'yes'].includes(String(value).toLowerCase())) {
          this.filters.open_now = '1';
          return;
        }
        if (key === 'time_field') {
          this.filters.time_field = value;
          return;
        }
        const facet = this.facets.find(f => f.name === key);
        if (!facet) return;
        if (facet.values?.length && !facet.values.includes(value)) return;
        this.filters[key] = value;
      });
    },

    defaultFilterValue(name) {
      const facet = this.facets.find(f => f.name === name);
      return facet?.default || null;
    },

    async loadRows() {
      this.rowsLoading = true;
      try {
        const qs = this.queryParams();
        const r = await fetch(`/api/category/${encodeURIComponent(this.category)}/records?${qs.toString()}`);
        this.rows = r.ok ? await r.json() : [];
        this.reconcileSelectedRow();
      } catch (_) {
        this.rows = [];
        this.reconcileSelectedRow();
      } finally {
        this.rowsLoading = false;
      }
    },

    reconcileSelectedRow() {
      if (!this.eventCategory()) return;
      const currentId = this.selected?.external_id;
      const match = currentId && this.rows.find(row => row.external_id === currentId);
      this.selected = match || this.rows[0] || null;
    },

    eventListGroups() {
      const groups = [];
      const byKey = new Map();
      (this.rows || []).forEach((row) => {
        const date = this.eventStartDate(row);
        const key = this.calendarDateKey(date) || 'date-tba';
        if (!byKey.has(key)) {
          const group = {
            key,
            label: this.eventDayLabel(date),
            sublabel: this.eventDaySublabel(date),
            timing: this.eventTimingFromDate(date),
            rows: []
          };
          byKey.set(key, group);
          groups.push(group);
        }
        byKey.get(key).rows.push(row);
      });
      return groups.map((group) => ({
        ...group,
        countLabel: `${group.rows.length} ${group.rows.length === 1 ? 'event' : 'events'}`
      }));
    },

    eventTiming(row) {
      return this.eventTimingFromDate(this.eventStartDate(row));
    },

    eventTimingFromDate(date) {
      if (!date || isNaN(date.getTime())) return 'unscheduled';
      const key = this.calendarDateKey(date);
      const todayKey = this.calendarDateKey(new Date());
      if (key === todayKey) return 'today';
      return key > todayKey ? 'upcoming' : 'past';
    },

    selectEventDay(dayKey) {
      const group = this.eventListGroups().find((entry) => entry.key === dayKey);
      if (!group || group.rows.length === 0) return;
      this.select(group.rows[0], { focusMap: false, scrollRow: false });
      this.$nextTick(() => {
        const container = this.$refs.listRows;
        const target = [...(container?.querySelectorAll('[data-event-day]') || [])]
          .find((node) => node.dataset.eventDay === dayKey);
        if (!container || !target) return;
        const top = target.getBoundingClientRect().top -
          container.getBoundingClientRect().top +
          container.scrollTop;
        container.scrollTo({ top, behavior: 'smooth' });
      });
    },

    toggleFilter(name, value) {
      if (name === 'time_range') {
        this.filters[name] = value;
      } else {
        this.filters[name] = this.filters[name] === value ? null : value;
      }
      this._geoFitPending = true;
      this.loadRows().catch(() => { this.rows = []; });
      this.refreshGeo().catch(() => {});
    },

    toggleOpenNow() {
      if (!this.showOpenNowToggle) return;
      if (this.openNowActive) {
        delete this.filters.open_now;
      } else {
        this.filters.open_now = '1';
      }
      this._geoFitPending = true;
      this.loadRows().catch(() => { this.rows = []; });
      this.refreshGeo().catch(() => {});
    },

    clearFilters() {
      this.filters = {};
      this.applyDefaultFilters();
      this._geoFitPending = true;
      this.loadRows().catch(() => { this.rows = []; });
      this.refreshGeo().catch(() => {});
    },

    facetLabel(facet) {
      if (facet?.label) return facet.label;
      return (facet?.name || '').replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    },

    facetValueLabel(facet, value) {
      if (facet?.name === 'time_range') {
        if (value === 'latest') return 'Latest data';
        if (facet.future) {
          return {
            upcoming: 'Upcoming',
            tonight: 'Tonight',
            today: 'Today',
            tomorrow: 'Tomorrow',
            '7d': 'Next 7 days',
            '30d': 'Next 30 days'
          }[value] || value;
        }
        return `${facet.source_anchored ? 'Latest' : 'Last'} ${value}`;
      }
      return value;
    },

    typeHint(row) {
      return row?._record_class?.split('::').pop();
    },

    showRowTime(row) {
      if (['Tree', 'Park', 'FoodTruck', 'MeteredParkingSpace'].includes(this.typeHint(row))) return false;
      return true;
    },

    rowTitle(row) {
      if (!row) return '';
      const fields = MUNI_TITLE_FIELDS[this.typeHint(row)] || MUNI_DEFAULT_TITLE_FIELDS;
      for (const f of fields) {
        if (row[f]) return row[f];
      }
      return row.external_id || '';
    },

    rowSubtitle(row) {
      if (!row) return '';
      const fields = MUNI_SUBTITLE_FIELDS[this.typeHint(row)] || MUNI_DEFAULT_SUBTITLE_FIELDS;
      for (const f of fields) {
        const v = row[f];
        if (f === 'species_scientific' && !this.hasScientificName(row)) continue;
        if (v) return typeof v === 'string' ? v : this.relativeTime({ [f]: v });
      }
      return '';
    },

    rowMeta(row) {
      if (!row) return [];
      const defs = MUNI_META_FIELDS[this.typeHint(row)] || [];
      return this.compactMeta(defs.map(def => this.metaFromDefinition(row, def)));
    },

    compactMeta(items) {
      return items.filter(item => item && item.value !== null && item.value !== undefined && item.value !== '');
    },

    metaItem(label, value, tone = null) {
      return { label, value, tone };
    },

    metaFromDefinition(row, def) {
      if (def.require === 'scientific_name' && !this.hasScientificName(row)) return null;

      const value = this.metaValue(row, def);
      const tone = def.tone === 'status' ? this.dotClassFromRow(row) : def.tone;
      return this.metaItem(def.label, value, tone);
    },

    metaValue(row, def) {
      const raw = def.synthetic === 'crash_status' ? this.crashStatus(row) : row[def.field];
      switch (def.format) {
        case 'short_date':
          return raw && this.shortDate(raw);
        case 'money':
          return this.formatMoney(raw);
        case 'diameter':
          return this.formatDiameter(raw);
        default:
          return raw;
      }
    },

    rowStatusClass(row) {
      return this.dotClassFromRow(row);
    },

    rowDotClass(row) {
      if (this.dotClassFromRow(row)) return this.dotClassFromRow(row);
      if (this.defaultWidget === 'map' && !this.mapTheme().statusDots) return 'cat';
      return '';
    },

    rowDotStyle(row) {
      if (row?._incident_kind && MUNI_DOT_COLORS[row._incident_kind]) {
        return { background: MUNI_DOT_COLORS[row._incident_kind] };
      }
      if (this.dotClassFromRow(row)) return null;
      if (this.eventCategory()) return null;
      if (this.defaultWidget === 'map' && !this.mapTheme().statusDots) {
        return { background: this.mapTheme().accent };
      }
      return null;
    },

    dotClassFromRow(row) {
      if (!row) return '';
      const lifecycle = (row.lifecycle_status || '').toString().toLowerCase();
      if (MUNI_DOT_COLORS[lifecycle]) return lifecycle;
      if (this.typeHint(row) === 'Crash' || 'fatal' in row || 'injury' in row) {
        if (this.truthy(row.fatal)) return 'fatal';
        if (this.truthy(row.injury)) return 'injury';
        if (this.typeHint(row) === 'Crash') return 'no_injury';
      }
      if (this.typeHint(row) === 'Tree') {
        const condition = (row.condition || row.species_common || '').toString().toLowerCase();
        if (condition.includes('retired')) return 'retired';
        if (condition.includes('stump')) return 'stump';
        if (condition.includes('planting') || condition.includes('proposed')) return 'planting';
        if (condition.includes('tree') || condition.includes('city') || condition.includes('dcr')) return 'tree';
      }
      if (this.typeHint(row) === 'Park') return 'park';
      if (this.typeHint(row) === 'FoodTruck') return '';
      if (this.typeHint(row) === 'MeteredParkingSpace') {
        const key = (row.meter_status_key || '').toString();
        if (key === 'paid_now') return 'parking_paid';
        if (key === 'outside_meter_hours') return 'parking_outside';
        if (key === 'unknown_rules' || row.rule_status === 'unknown_rules') return 'parking_unknown';
        return '';
      }

      const incident = (row._incident_kind || '').toString();
      if (incident) return incident;

      const s = (row.display_status || row.status || row.severity || row.ticket_status || row.current_status || '').toString().toLowerCase();
      if (s.includes('stale')) return 'stale';
      if (s.includes('acknowledged')) return 'acknowledged';
      if (s.includes('open') || s.includes('active') || s.includes('in_transit')) return 'open';
      if (s.includes('closed') || s.includes('resolved') || s.includes('stopped') || s.includes('complete')) return 'closed';
      if (s.includes('archived')) return 'archived';
      if (s.includes('pending')) return 'pending';
      return '';
    },

    truthy(value) {
      return value === true || value === 1 || ['1', 'true', 't', 'yes', 'y'].includes(String(value).toLowerCase());
    },

    crashStatus(row) {
      if (this.truthy(row?.fatal)) return 'Fatal';
      if (this.truthy(row?.injury)) return 'Injury';
      return 'No injury';
    },

    mapTheme() {
      return MUNI_CATEGORY_MAP[this.category] || MUNI_CATEGORY_MAP.default;
    },

    mapPointColor() {
      const theme = this.mapTheme();
      if (theme.incidentDots) {
        return ['match', ['get', '_incident_kind'],
          'police_log', MUNI_DOT_COLORS.police_log,
          'crime', MUNI_DOT_COLORS.crime,
          'dispatch_fire', MUNI_DOT_COLORS.dispatch_fire,
          'dispatch_police', MUNI_DOT_COLORS.dispatch_police,
          'recent_crash', MUNI_DOT_COLORS.recent_crash,
          theme.accent];
      }
      if (theme.statusDots) {
        return ['match', ['get', 'dot'],
          'open', MUNI_DOT_COLORS.open,
          'closed', MUNI_DOT_COLORS.closed,
          'pending', MUNI_DOT_COLORS.pending,
          'acknowledged', MUNI_DOT_COLORS.acknowledged,
          'stale', MUNI_DOT_COLORS.stale,
          'archived', MUNI_DOT_COLORS.archived,
          'fatal', MUNI_DOT_COLORS.fatal,
          'injury', MUNI_DOT_COLORS.injury,
          'no_injury', MUNI_DOT_COLORS.no_injury,
          'tree', MUNI_DOT_COLORS.tree,
          'retired', MUNI_DOT_COLORS.retired,
          'stump', MUNI_DOT_COLORS.stump,
          'planting', MUNI_DOT_COLORS.planting,
          'park', MUNI_DOT_COLORS.park,
          'parking_paid', MUNI_DOT_COLORS.parking_paid,
          'parking_outside', MUNI_DOT_COLORS.parking_outside,
          'parking_unknown', MUNI_DOT_COLORS.parking_unknown,
          MUNI_DOT_COLORS['']];
      }
      return theme.accent;
    },

    select(row, options = {}) {
      const previousId = this.selected?.external_id;
      this.selected = row;
      if (this.isParkingRecord(row) && previousId !== row.external_id) {
        this.parkingDurationMinutes = this.parkingInitialDuration(row);
      }
      this.updateSelectedMapFilter();
      if (options.focusMap !== false) this.highlight(row, options);
      const collapseParkingList = this.isParkingRecord(row) && this.defaultWidget === 'map';
      if (collapseParkingList) {
        this.mobileListOpen = false;
        if (this.isMobileViewport()) window.scrollTo({ top: 0, behavior: 'smooth' });
        this.$nextTick(() => this.resizeMap());
      }
      this.$nextTick(() => {
        if (options.scrollRow === false) return;
        if (collapseParkingList && this.isMobileViewport()) return;
        const el = document.querySelector('.row.is-active');
        el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
      });
    },

    isParkingRecord(row) {
      return this.typeHint(row) === 'MeteredParkingSpace' || (this.category === 'parking' && Boolean(row?.space_id));
    },

    parkingInitialDuration(row) {
      const max = this.parkingMaxMinutes(row);
      return max ? Math.min(60, max) : 60;
    },

    parkingMinimumDuration(row) {
      return Math.min(15, this.parkingDurationLimit(row));
    },

    parkingDurationLimit(row) {
      const max = this.parkingMaxMinutes(row);
      return max && max > 0 ? max : 240;
    },

    parkingMaxMinutes(row) {
      const minutes = Number(row?.max_minutes);
      return Number.isFinite(minutes) && minutes > 0 ? Math.round(minutes) : null;
    },

    parkingStepMinutes() {
      return 15;
    },

    adjustParkingDuration(delta) {
      if (!this.isParkingRecord(this.selected)) return;
      const limit = this.parkingDurationLimit(this.selected);
      const min = this.parkingMinimumDuration(this.selected);
      const next = Math.min(limit, Math.max(min, this.parkingDurationMinutes + delta));
      this.parkingDurationMinutes = next;
    },

    canAdjustParkingDuration(delta) {
      if (!this.isParkingRecord(this.selected)) return false;
      const next = this.parkingDurationMinutes + delta;
      return next >= this.parkingMinimumDuration(this.selected) && next <= this.parkingDurationLimit(this.selected);
    },

    parkingPricedMinutes(row) {
      const duration = Number(this.parkingDurationMinutes);
      if (!Number.isFinite(duration) || duration <= 0) return 0;
      const max = this.parkingMaxMinutes(row);
      return max ? Math.min(duration, max) : duration;
    },

    parkingBillableMinutes(row) {
      if (!this.parkingRulesKnown(row)) return null;
      return this.parkingPricedMinutes(row);
    },

    parkingRulesKnown(row) {
      if (!row) return false;
      if (row.rule_status === 'unknown_rules' || row.meter_status_key === 'unknown_rules') return false;
      return Number.isFinite(Number(row.hourly_rate)) && Number(row.hourly_rate) > 0;
    },

    parkingCostAmount(row) {
      const rate = Number(row?.hourly_rate);
      const minutes = this.parkingBillableMinutes(row);
      if (!Number.isFinite(rate) || rate <= 0 || minutes === null) return null;
      return Math.round((minutes / 60) * rate * 100) / 100;
    },

    parkingCostLabel(row) {
      const amount = this.parkingCostAmount(row);
      if (amount === null) return 'Price unknown';
      return `${this.formatMoney(amount, { allowZero: true })} USD`;
    },

    parkingCostCaption(row) {
      if (!this.parkingRulesKnown(row)) return 'Rules unknown';
      const base = `${this.parkingFormulaRate(row)} x ${this.parkingFormulaTime(row)}`;
      return this.parkingDurationExceedsMax(row) ? `${base}, capped by max stay` : base;
    },

    parkingFormulaRate(row) {
      return row?.rate_label || this.formatMoney(row?.hourly_rate) || 'Unknown';
    },

    parkingFormulaTime(row) {
      const minutes = this.parkingBillableMinutes(row);
      return minutes === null ? 'Unknown' : (this.formatMinutes(minutes) || '0 min');
    },

    parkingFormulaCost(row) {
      const amount = this.parkingCostAmount(row);
      return amount === null ? 'Unknown' : this.formatMoney(amount, { allowZero: true });
    },

    parkingDurationExceedsMax(row) {
      const max = this.parkingMaxMinutes(row);
      return Boolean(max && this.parkingDurationMinutes > max);
    },

    parkingWarning(row) {
      if (!this.parkingRulesKnown(row)) return 'Meter rules unavailable';
      if (this.parkingDurationExceedsMax(row)) return `Max stay ${row.max_time_label || this.formatMinutes(this.parkingMaxMinutes(row))}`;
      return '';
    },

    parkingFact(row, key) {
      if (!row) return 'Unknown';
      if (key === 'rate') return row.rate_label || this.formatMoney(row.hourly_rate) || 'Unknown';
      if (key === 'max') return row.max_time_label || this.formatMinutes(this.parkingMaxMinutes(row)) || 'Unknown';
      if (key === 'hours') return row.operation_window || row.operation_hours || 'Unknown';
      if (key === 'zone') return row.pay_by_phone_zone || 'Unknown';
      return 'Unknown';
    },

    formatPropValue(key, value) {
      if (key.startsWith('_')) return null;
      if (key === 'geometry') return null;
      if (typeof value === 'boolean') return value ? 'Yes' : 'No';
      if (['declared_valuation', 'hourly_rate'].includes(key)) return this.formatMoney(value);
      if (key === 'diameter_in') return this.formatDiameter(value);
      if (['max_minutes', 'minutes_per_payment'].includes(key)) return this.formatMinutes(value);
      if ([
        'opened_at', 'closed_at', 'occurred_at', 'issued_at', 'updated_at',
        'reported_at', 'published_at', 'event_start_at', 'event_end_at',
        'fetched_at', 'first_seen_at', 'last_seen_at',
        'acknowledged_at', 'applied_at', 'received_at', 'observed_at',
        'plant_date', 'removal_date', 'edited_at', 'collected_at',
        'applicant_submit_date', 'food_protection_certification_expires_at',
        'allergen_awareness_certification_expires_at', 'attested_at'
      ].includes(key)) {
        return this.formatDateTime(value);
      }
      if (key === 'location' && Array.isArray(value)) {
        const [lon, lat] = value;
        return `${lat?.toFixed(5)}, ${lon?.toFixed(5)}`;
      }
      if (key === 'source_url' && value) return value;
      return typeof value === 'object' ? JSON.stringify(value) : value;
    },

    propLabel(key) {
      return MUNI_PROP_LABELS[key] || key.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    },

    propIsLink(key) {
      return key === 'source_url' || key === 'image_url' || key === 'url' || key === 'agenda_url' || key === 'video_url';
    },

    get selectedProps() {
      if (!this.selected) return [];
      const skip = new Set(['polygon', 'geometry', '_source_scope', '_source_name', '_record_class']);
      if (this.typeHint(this.selected) === 'ServiceRequest') {
        ['collected_at', 'last_seen_at'].forEach(key => skip.add(key));
      }
      if (this.typeHint(this.selected) === 'FoodTruck') {
        [
          'equipment', 'refrigeration_method', 'soft_serve_machine', 'food_handler_count',
          'sanitizer_type', 'prep_location', 'toilet_facilities',
          'food_protection_certification_expires_at', 'allergen_awareness_certification_expires_at',
          'attested_at', 'grouped_record', 'source_external_ids', 'schedule_entries',
          'service_days', 'service_day_count', 'stop_count'
        ].forEach(key => skip.add(key));
      }
      if (this.isParkingRecord(this.selected)) {
        [
          'meter_status', 'meter_status_key', 'space_id', 'pay_by_phone_zone',
          'max_time_label', 'rate_label', 'operation_window', 'operation_hours',
          'max_minutes', 'hourly_rate', 'minutes_per_payment'
        ].forEach(key => skip.add(key));
      }
      const priority = [
        'meter_status', 'space_id', 'pay_by_phone_zone', 'max_time_label', 'rate_label',
        'operation_window', 'operation_hours', 'max_minutes', 'hourly_rate', 'minutes_per_payment',
        'status', 'case_type', 'crime_category', 'crime_subcategory', 'permit_type',
        'incident_type', 'incident_group', 'agency', 'priority', 'crash_type',
        'violation_description', 'violation_code', 'vehicle_class', 'count',
        'condition', 'species_common', 'truck_name', 'dba', 'business_name',
        'name', 'park_type', 'owner', 'acres',
        'weekday', 'hours', 'open_time', 'close_time', 'description', 'items_to_be_sold',
        'location_description', 'address', 'intersection', 'count_location', 'business_address',
        'neighborhood', 'department', 'reporting_area',
        'declared_valuation', 'amount_due', 'diameter_in',
        'property_use', 'proposed_use', 'ownership', 'injury', 'fatal', 'cyclist',
        'fcode', 'oscode', 'rcode',
        'pedestrian', 'motorists', 'cyclists', 'pedestrians', 'injuries', 'hospitalizations',
        'manner', 'first_harmful_event', 'opened_at', 'acknowledged_at',
        'closed_at', 'updated_at', 'occurred_at', 'reported_at', 'display_status', 'lifecycle_status', 'last_touched_at', 'applied_at',
        'issued_at', 'received_at', 'observed_at', 'applicant_submit_date', 'food_protection_certification_expires_at',
        'allergen_awareness_certification_expires_at', 'attested_at', 'plant_date',
        'removal_date', 'edited_at', 'order_number', 'food_handler_count', 'equipment',
        'refrigeration_method', 'soft_serve_machine', 'sanitizer_type',
        'prep_location', 'toilet_facilities', 'permit_id', 'viewpoint_id', 'location',
        'external_id', 'source_url', 'image_url', '_source_slug', 'hall'
      ];
      return Object.entries(this.selected).filter(([k, v]) => {
        if (skip.has(k) || v === null || v === undefined || v === '') return;
        const formatted = this.formatPropValue(k, v);
        return formatted !== null && formatted !== '';
      }).sort(([a], [b]) => {
        const ai = priority.includes(a) ? priority.indexOf(a) : priority.length;
        const bi = priority.includes(b) ? priority.indexOf(b) : priority.length;
        return ai - bi;
      }).map(([key, value]) => ({
        key,
        label: this.propLabel(key),
        value: this.formatPropValue(key, value),
        link: this.propIsLink(key)
      }));
    },

    primarySource() {
      return this.categoryConfig?.primary_source
          || this.categoryConfig?.source_slugs?.find(s => s.startsWith(this.hall + '/'));
    },

    registerPmtilesProtocol() {
      if (this._pmtilesReady || typeof pmtiles === 'undefined') return;
      try {
        const protocol = new pmtiles.Protocol();
        maplibregl.addProtocol('pmtiles', protocol.tile);
        this._pmtilesReady = true;
      } catch (_) { /* already registered */ }
    },

    pmtilesStyleUrl() {
      const path = window.MUNI_PMTILES_URL || '/tiles/muni.pmtiles';
      const origin = window.location?.origin || '';
      const url = path.startsWith('http') ? path : `${origin}${path}`;
      return `pmtiles://${url}`;
    },

    pmtilesStyle() {
      if (window.MUNI_BASEMAP_MODE === 'raster' || !window.MUNI_PMTILES_READY) return null;
      const basemapLayers = window.basemaps?.layers;
      const basemapFlavor = window.basemaps?.namedFlavor;
      if (typeof basemapLayers !== 'function' || typeof basemapFlavor !== 'function') return null;
      this.registerPmtilesProtocol();
      return {
        version: 8,
        glyphs: this.mapGlyphsUrl(),
        sprite: window.MUNI_MAP_SPRITE || 'https://protomaps.github.io/basemaps-assets/sprites/v4/light',
        sources: {
          protomaps: {
            type: 'vector',
            url: this.pmtilesStyleUrl(),
            attribution: '© OpenStreetMap © Protomaps'
          }
        },
        layers: basemapLayers('protomaps', basemapFlavor('light'), { lang: 'en' })
      };
    },

    basemapTileUrls() {
      if (window.MUNI_BASEMAP_MODE === 'pmtiles') return null;
      if (window.MUNI_MAP_TILES) {
        const t = window.MUNI_MAP_TILES;
        return Array.isArray(t) ? t : [t];
      }
      if (window.MUNI_MAP_STYLE) return null;
      const host = window.location?.hostname || '';
      const local = host === 'localhost' || host === '127.0.0.1' || host === '';
      if (!local && window.location?.origin) {
        return [`${window.location.origin}/basemap/light/{z}/{x}/{y}.png`];
      }
      return [
        'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
        'https://b.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
        'https://c.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
        'https://d.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png'
      ];
    },

    mapStyle() {
      const key = window.MUNI_MAPTILER_KEY || '';
      if (key) return `https://api.maptiler.com/maps/dataviz-light/style.json?key=${key}`;

      const styleUrl = window.MUNI_MAP_STYLE;
      if (styleUrl) return styleUrl;

      const pm = this.pmtilesStyle();
      if (pm) return pm;

      const tiles = this.basemapTileUrls();
      if (!tiles) return styleUrl;

      return {
        version: 8,
        glyphs: this.mapGlyphsUrl(),
        sources: {
          basemap: {
            type: 'raster',
            tiles: tiles,
            tileSize: 256,
            attribution: '© OpenStreetMap © CARTO'
          }
        },
        layers: [{
          id: 'basemap',
          type: 'raster',
          source: 'basemap',
          paint: {
            'raster-opacity': 1,
            'raster-saturation': -0.15,
            'raster-contrast': 0.05,
            'raster-brightness-min': 0.02,
            'raster-brightness-max': 0.98
          }
        }]
      };
    },

    mapGlyphsUrl() {
      return window.MUNI_MAP_GLYPHS ||
        'https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf';
    },

    async maybeInitMap() {
      if (this.defaultWidget !== 'map') return;
      if (!this.map) {
        const center = JSON.parse(this.$root.dataset.center);
        const style = this.mapStyle();
        if (!style) {
          this.mapError = window.MUNI_BASEMAP_ERROR || 'Basemap is not configured.';
          return;
        }
        this.mapError = null;
        const mapOptions = {
          container: 'map',
          style,
          center, zoom: 12,
          attributionControl: { compact: true }
        };
        const maxBounds = this.hallMaxBounds();
        if (maxBounds) mapOptions.maxBounds = maxBounds;
        this.map = new maplibregl.Map(mapOptions);
        this.map.addControl(new maplibregl.NavigationControl({ showCompass: false }));
        this.map.on('load', () => {
          this.mapError = null;
          this.installHallBoundary();
          this.fitMapToHall({ duration: 0 });
          this.refreshGeo();
        });
        this.map.on('error', (e) => {
          if (e?.error?.message) this.mapError = e.error.message;
        });
      }
      await this.refreshGeo();
      this.$nextTick(() => this.resizeMap());
    },

    retryMap() {
      if (!this.map) {
        this.maybeInitMap();
        return;
      }
      const style = this.mapStyle();
      if (!style) {
        this.mapError = window.MUNI_BASEMAP_ERROR || 'Basemap is not configured.';
        return;
      }
      this.mapError = null;
      this.map.setStyle(style);
      this.map.once('load', () => {
        this.installHallBoundary();
        this.refreshGeo();
      });
    },

    resizeMap() {
      this.map?.resize();
    },

    hallBbox() {
      try {
        return JSON.parse(this.$root.dataset.bbox || 'null');
      } catch (_) {
        return null;
      }
    },

    hallBoundary() {
      try {
        const boundary = JSON.parse(this.$root.dataset.boundary || 'null');
        return boundary?.coordinates ? boundary : null;
      } catch (_) {
        return null;
      }
    },

    hallBoundaryGeometry() {
      const boundary = this.hallBoundary();
      if (!boundary) return null;
      return { type: boundary.type || 'Polygon', coordinates: boundary.coordinates };
    },

    hallBoundaryFeature() {
      const geometry = this.hallBoundaryGeometry();
      return geometry && { type: 'Feature', geometry, properties: { hall: this.hall } };
    },

    hallMaskFeature() {
      const boundary = this.hallBoundaryGeometry();
      const bbox = this.hallBbox();
      if (!boundary || !bbox) return null;
      const holes = this.boundaryMaskHoles(boundary);
      if (!holes.length) return null;
      const [west, south, east, north] = bbox;
      const pad = 1;
      const outer = [
        [west - pad, south - pad],
        [east + pad, south - pad],
        [east + pad, north + pad],
        [west - pad, north + pad],
        [west - pad, south - pad]
      ];
      return {
        type: 'Feature',
        geometry: { type: 'Polygon', coordinates: [outer, ...holes] },
        properties: { hall: this.hall }
      };
    },

    boundaryMaskHoles(boundary) {
      if (boundary.type === 'Polygon') return [boundary.coordinates[0]].filter(Boolean);
      if (boundary.type !== 'MultiPolygon') return [];
      return boundary.coordinates.map((polygon) => polygon?.[0]).filter(Boolean);
    },

    hallMaxBounds() {
      const bbox = this.hallBbox();
      if (!bbox) return null;
      const [west, south, east, north] = bbox;
      return [[west - 0.012, south - 0.01], [east + 0.012, north + 0.01]];
    },

    fitMapToHall(options = {}) {
      const bbox = this.hallBbox();
      if (!this.map || !bbox) return;
      const [west, south, east, north] = bbox;
      this.map.fitBounds([[west, south], [east, north]], {
        padding: 42,
        maxZoom: 13,
        duration: options.duration ?? 0
      });
    },

    installHallBoundary() {
      if (!this.map?.isStyleLoaded()) return;
      const boundary = this.hallBoundaryFeature();
      if (!boundary) return;
      const mask = this.hallMaskFeature();

      if (mask) {
        const data = { type: 'FeatureCollection', features: [mask] };
        const maskPaint = { 'fill-color': '#dfe3e8', 'fill-opacity': 0.42 };
        if (this.map.getSource('hall-mask')) {
          this.map.getSource('hall-mask').setData(data);
        } else {
          this.map.addSource('hall-mask', { type: 'geojson', data });
        }
        if (!this.map.getLayer('hall-boundary-mask')) {
          this.map.addLayer({
            id: 'hall-boundary-mask',
            type: 'fill',
            source: 'hall-mask',
            paint: maskPaint
          });
        } else {
          Object.entries(maskPaint).forEach(([property, value]) => {
            this.map.setPaintProperty('hall-boundary-mask', property, value);
          });
        }
      }

      const boundaryData = { type: 'FeatureCollection', features: [boundary] };
      if (this.map.getSource('hall-boundary')) {
        this.map.getSource('hall-boundary').setData(boundaryData);
      } else {
        this.map.addSource('hall-boundary', { type: 'geojson', data: boundaryData });
      }
      if (!this.map.getLayer('hall-boundary-line')) {
        this.map.addLayer({
          id: 'hall-boundary-line',
          type: 'line',
          source: 'hall-boundary',
          paint: {
            'line-color': '#4b5563',
            'line-width': ['interpolate', ['linear'], ['zoom'], 10, 1.4, 13, 2.2, 16, 3.4],
            'line-opacity': 0.95
          }
        });
      }
    },

    useCluster(geojson) {
      const theme = this.mapTheme();
      if (!theme.cluster) return false;
      return (geojson?.features?.length || 0) > 200;
    },

    enrichGeojson(geojson) {
      const features = (geojson.features || []).filter((f) => {
        const coords = this.featureAnchorCoords(f);
        return !coords || this.pointInHallBoundary(coords);
      }).map((f) => {
        const props = { ...(f.properties || {}) };
        props.dot = this.dotClassFromRow(props);
        return { ...f, properties: props };
      });
      return { ...geojson, features };
    },

    featureAnchorCoords(feature) {
      const propLocation = feature?.properties?.location;
      if (Array.isArray(propLocation) && propLocation.length >= 2 && propLocation.every(Number.isFinite)) {
        return propLocation;
      }
      const coordinates = this.geometryCoordinates(feature?.geometry);
      if (!coordinates.length) return null;
      const sum = coordinates.reduce((memo, [lon, lat]) => {
        memo.lon += lon;
        memo.lat += lat;
        return memo;
      }, { lon: 0, lat: 0 });
      return [sum.lon / coordinates.length, sum.lat / coordinates.length];
    },

    geometryCoordinates(geometry) {
      const coords = [];
      const walk = (value) => {
        if (!Array.isArray(value)) return;
        if (value.length >= 2 && Number.isFinite(value[0]) && Number.isFinite(value[1])) {
          coords.push([value[0], value[1]]);
          return;
        }
        value.forEach(walk);
      };
      walk(geometry?.coordinates);
      return coords;
    },

    pointInHallBoundary(coords) {
      const boundary = this.hallBoundaryGeometry();
      if (!boundary) return true;
      const [lon, lat] = coords || [];
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) return false;
      if (boundary.type === 'Polygon') return this.pointInPolygon(lon, lat, boundary.coordinates);
      if (boundary.type === 'MultiPolygon') {
        return boundary.coordinates.some((polygon) => this.pointInPolygon(lon, lat, polygon));
      }
      return true;
    },

    pointInPolygon(lon, lat, rings) {
      if (!rings?.length) return false;
      const insideOuter = this.pointInRing(lon, lat, rings[0]);
      const insideHole = rings.slice(1).some((ring) => this.pointInRing(lon, lat, ring));
      return insideOuter && !insideHole;
    },

    pointInRing(lon, lat, ring) {
      let inside = false;
      for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        const [xi, yi] = ring[i];
        const [xj, yj] = ring[j];
        if (this.pointOnSegment(lon, lat, xi, yi, xj, yj)) return true;
        const intersects = ((yi > lat) !== (yj > lat)) &&
          (lon < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
        if (intersects) inside = !inside;
      }
      return inside;
    },

    pointOnSegment(lon, lat, xi, yi, xj, yj) {
      const cross = (lat - yi) * (xj - xi) - (lon - xi) * (yj - yi);
      if (Math.abs(cross) > 1e-10) return false;
      return lon >= Math.min(xi, xj) && lon <= Math.max(xi, xj) &&
        lat >= Math.min(yi, yj) && lat <= Math.max(yi, yj);
    },

    clearMapLayers() {
      if (!this.map?.isStyleLoaded()) return;
      try {
        [
          'records-clusters', 'records-cluster-count', 'records-pts',
          'records-polygons-line', 'records-polygons-fill',
          'records-selection-line', 'records-selection-fill', 'records-selection-pt'
        ].forEach((id) => {
          if (this.map.getLayer(id)) this.map.removeLayer(id);
        });
        if (this.map.getSource('records')) this.map.removeSource('records');
        if (this.map.getSource('records-points')) this.map.removeSource('records-points');
        if (this.map.getSource('records-polygons')) this.map.removeSource('records-polygons');
      } catch (_) { /* style churn */ }
    },

    clearParkingLocationLayer() {
      if (!this.map?.isStyleLoaded()) return;
      try {
        ['parking-user-dot', 'parking-user-halo'].forEach((id) => {
          if (this.map.getLayer(id)) this.map.removeLayer(id);
        });
        if (this.map.getSource('parking-user-location')) this.map.removeSource('parking-user-location');
      } catch (_) { /* style churn */ }
    },

    scheduleGeoRefresh() {
      if (this._geoRefreshTimer) clearTimeout(this._geoRefreshTimer);
      this._geoRefreshTimer = setTimeout(() => this.refreshGeo(), 2000);
    },

    async refreshGeo() {
      const cat = this.category;
      if (!this.map || this.defaultWidget !== 'map') return;
      const qs = this.geoQueryParams();
      let r;
      try {
        r = await fetch(`/api/category/${encodeURIComponent(this.category)}/geo?${qs.toString()}`);
      } catch (_) {
        if (cat === this.category) this.geoFeatureCount = null;
        return;
      }
      if (!r.ok || cat !== this.category) return;
      const geojson = this.enrichGeojson(await r.json());
      if (cat === this.category) this.geoFeatureCount = geojson.features?.length || 0;
      if (cat !== this.category) return;
      if (this.map.isStyleLoaded()) {
        this.installGeoLayer(geojson);
      } else {
        this.map.once('load', () => {
          if (this.category === cat) this.installGeoLayer(geojson);
        });
      }
    },

    fitMapToData(geojson) {
      const coords = (geojson.features || [])
        .flatMap((f) => this.geometryCoordinates(f.geometry));
      if (!coords.length) return;
      const bounds = coords.reduce((b, [lon, lat]) => ({
        west: Math.min(b.west, lon), east: Math.max(b.east, lon),
        south: Math.min(b.south, lat), north: Math.max(b.north, lat)
      }), { west: coords[0][0], east: coords[0][0], south: coords[0][1], north: coords[0][1] });
      if (![bounds.west, bounds.east, bounds.south, bounds.north].every(Number.isFinite)) return;
      if (bounds.west === bounds.east && bounds.south === bounds.north) {
        this.map.flyTo({ center: [bounds.west, bounds.south], zoom: 14, duration: 600 });
        return;
      }
      const mapBounds = [[bounds.west, bounds.south], [bounds.east, bounds.north]];
      const options = { padding: 48, maxZoom: 14 };
      const camera = this.map.cameraForBounds?.(mapBounds, options);
      if (camera) {
        const minZoom = this.categoryMinDataZoom();
        this.map.easeTo({
          ...camera,
          zoom: minZoom ? Math.max(camera.zoom, minZoom) : camera.zoom,
          duration: 600
        });
        return;
      }
      this.map.fitBounds(mapBounds, { ...options, duration: 600 });
    },

    categoryMinDataZoom() {
      return this.category === 'parking' ? 13.75 : null;
    },

    geojsonWithGeometryTypes(geojson, types) {
      const allow = new Set(types);
      const features = (geojson.features || []).filter((feature) => allow.has(feature?.geometry?.type));
      return { ...geojson, features };
    },

    installGeoLayer(geojson) {
      if (!this.map?.isStyleLoaded()) return;
      const theme = this.mapTheme();
      const pointGeojson = this.geojsonWithGeometryTypes(geojson, ['Point']);
      const polygonGeojson = this.geojsonWithGeometryTypes(geojson, ['Polygon', 'MultiPolygon']);
      const hasPolygons = theme.polygon && (polygonGeojson.features || []).length > 0;
      const cluster = this.useCluster(pointGeojson);
      const pointColor = this.mapPointColor();
      const accent = theme.accent;
      const fit = this._geoFitPending;

      this.clearMapLayers();
      try {
        this.installHallBoundary();
        this.map.addSource('records-points', {
          type: 'geojson',
          data: pointGeojson,
          cluster: cluster,
          clusterMaxZoom: 14,
          clusterRadius: 50
        });
        if (hasPolygons) {
          this.map.addSource('records-polygons', {
            type: 'geojson',
            data: polygonGeojson
          });
          this.map.addLayer({
            id: 'records-polygons-fill',
            type: 'fill',
            source: 'records-polygons',
            paint: {
              'fill-color': pointColor,
              'fill-opacity': 0.28
            }
          });
          this.map.addLayer({
            id: 'records-polygons-line',
            type: 'line',
            source: 'records-polygons',
            paint: {
              'line-color': pointColor,
              'line-width': ['interpolate', ['linear'], ['zoom'], 12, 1, 16, 2.4, 19, 4],
              'line-opacity': 0.9
            }
          });
        }

        if (cluster) {
          this.map.addLayer({
            id: 'records-clusters',
            type: 'circle',
            source: 'records-points',
            filter: ['has', 'point_count'],
            paint: {
              'circle-color': accent,
              'circle-radius': ['step', ['get', 'point_count'], 16, 50, 22, 200, 28],
              'circle-opacity': 0.75,
              'circle-stroke-width': 2,
              'circle-stroke-color': '#FFFFFF'
            }
          });
          this.map.addLayer({
            id: 'records-cluster-count',
            type: 'symbol',
            source: 'records-points',
            filter: ['has', 'point_count'],
            layout: { 'text-field': '{point_count_abbreviated}', 'text-size': 11 },
            paint: { 'text-color': '#ffffff' }
          });
        }

        if (hasPolygons) {
          this.map.addLayer({
            id: 'records-selection-fill',
            type: 'fill',
            source: 'records-polygons',
            filter: this.selectedPolygonFilter(),
            paint: {
              'fill-color': '#111827',
              'fill-opacity': 0.22
            }
          });
          this.map.addLayer({
            id: 'records-selection-line',
            type: 'line',
            source: 'records-polygons',
            filter: this.selectedPolygonFilter(),
            paint: {
              'line-color': '#111827',
              'line-width': ['interpolate', ['linear'], ['zoom'], 13, 2.5, 17, 5, 19, 7],
              'line-opacity': 0.95
            }
          });
        }

        const ptLayer = {
          id: 'records-pts',
          type: 'circle',
          source: 'records-points',
          paint: {
            'circle-radius': theme.radius,
            'circle-color': pointColor,
            'circle-stroke-width': 1.5,
            'circle-stroke-color': '#FFFFFF',
            'circle-opacity': 0.92
          }
        };
        if (cluster) {
          ptLayer.filter = ['all',
            ['!', ['has', 'point_count']],
            ['match', ['geometry-type'], ['Point'], true, false]
          ];
        } else if (theme.polygon) {
          ptLayer.filter = ['match', ['geometry-type'], ['Point'], true, false];
        }
        this.map.addLayer(ptLayer);
        this.map.addLayer({
          id: 'records-selection-pt',
          type: 'circle',
          source: 'records-points',
          filter: this.selectedPointFilter(),
          paint: {
            'circle-radius': theme.radius + 5,
            'circle-color': '#111827',
            'circle-opacity': 0.18,
            'circle-stroke-width': 2,
            'circle-stroke-color': '#111827',
            'circle-stroke-opacity': 0.85
          }
        });
        if (this.map.getLayer('hall-boundary-line')) this.map.moveLayer('hall-boundary-line');

        if (this.category === 'parking') this.installParkingLocationLayer();

        if (fit) {
          if (this.category === 'parking' && this.focusParkingNearUser({ duration: 600 })) {
            // Location focus wins over whole-city data fitting for parking.
          } else if ((geojson.features || []).length > 0) {
            this.fitMapToData(geojson);
          } else {
            this.fitMapToHall({ duration: 600 });
          }
          this._geoFitPending = false;
        }
      } catch (_) { return; }

      this.bindMapLayerEvents('records-pts');
      if (hasPolygons) this.bindMapLayerEvents('records-polygons-fill');
      this.updateSelectedMapFilter();
    },

    selectedFeatureFilter() {
      if (Array.isArray(this.selected?.source_external_ids) && this.selected.source_external_ids.length > 0) {
        return ['in', ['get', 'external_id'], ['literal', this.selected.source_external_ids]];
      }
      const id = this.selected?.external_id || '__none__';
      return ['==', ['get', 'external_id'], id];
    },

    selectedPolygonFilter() {
      return ['all', this.selectedFeatureFilter(), ['match', ['geometry-type'], ['Polygon', 'MultiPolygon'], true, false]];
    },

    selectedPointFilter() {
      return ['all', this.selectedFeatureFilter(), ['match', ['geometry-type'], ['Point'], true, false]];
    },

    updateSelectedMapFilter() {
      if (!this.map?.isStyleLoaded()) return;
      try {
        if (this.map.getLayer('records-selection-fill')) this.map.setFilter('records-selection-fill', this.selectedPolygonFilter());
        if (this.map.getLayer('records-selection-line')) this.map.setFilter('records-selection-line', this.selectedPolygonFilter());
        if (this.map.getLayer('records-selection-pt')) this.map.setFilter('records-selection-pt', this.selectedPointFilter());
      } catch (_) { /* layer churn */ }
    },

    maybeRequestParkingLocation() {
      if (this.category !== 'parking' || !this.map) return;
      if (this.parkingUserLocation) {
        this.installParkingLocationLayer();
        this.focusParkingNearUser({ duration: 600 });
        return;
      }
      if (this.parkingLocationRequested) return;
      if (!navigator.geolocation) {
        this.parkingLocationError = 'unavailable';
        return;
      }
      this.parkingLocationRequested = true;
      this.parkingLocationPending = true;
      this.parkingLocationError = null;
      navigator.geolocation.getCurrentPosition(
        (position) => this.receiveParkingLocation(position),
        (error) => {
          this.parkingLocationPending = false;
          this.parkingLocationError = error?.code || 'denied';
        },
        { enableHighAccuracy: true, maximumAge: 60000, timeout: 10000 }
      );
    },

    receiveParkingLocation(position) {
      const lon = Number(position?.coords?.longitude);
      const lat = Number(position?.coords?.latitude);
      if (!Number.isFinite(lon) || !Number.isFinite(lat)) {
        this.parkingLocationPending = false;
        this.parkingLocationError = 'invalid';
        return;
      }
      this.parkingUserLocation = {
        coordinates: [lon, lat],
        accuracy: Number(position?.coords?.accuracy) || null,
        timestamp: position?.timestamp || Date.now()
      };
      this.parkingLocationPending = false;
      this.parkingLocationError = null;
      this.installParkingLocationLayer();
      this.focusParkingNearUser({ duration: 600 });
    },

    parkingLocationFeature() {
      const coords = this.parkingUserLocation?.coordinates;
      if (!Array.isArray(coords) || coords.length < 2 || !coords.every(Number.isFinite)) return null;
      return {
        type: 'Feature',
        geometry: { type: 'Point', coordinates: coords },
        properties: { accuracy: this.parkingUserLocation.accuracy || null }
      };
    },

    installParkingLocationLayer() {
      if (this.category !== 'parking' || !this.map?.isStyleLoaded()) return;
      const feature = this.parkingLocationFeature();
      if (!feature) return;
      const data = { type: 'FeatureCollection', features: [feature] };
      if (this.map.getSource('parking-user-location')) {
        this.map.getSource('parking-user-location').setData(data);
      } else {
        this.map.addSource('parking-user-location', { type: 'geojson', data });
      }
      if (!this.map.getLayer('parking-user-halo')) {
        this.map.addLayer({
          id: 'parking-user-halo',
          type: 'circle',
          source: 'parking-user-location',
          paint: {
            'circle-radius': 12,
            'circle-color': '#2563eb',
            'circle-opacity': 0.18,
            'circle-stroke-width': 1,
            'circle-stroke-color': '#2563eb',
            'circle-stroke-opacity': 0.3
          }
        });
      }
      if (!this.map.getLayer('parking-user-dot')) {
        this.map.addLayer({
          id: 'parking-user-dot',
          type: 'circle',
          source: 'parking-user-location',
          paint: {
            'circle-radius': 5,
            'circle-color': '#2563eb',
            'circle-stroke-width': 2,
            'circle-stroke-color': '#ffffff'
          }
        });
      }
    },

    focusParkingNearUser({ duration = 0 } = {}) {
      if (this.category !== 'parking' || !this.map) return false;
      const coords = this.parkingUserLocation?.coordinates;
      if (!Array.isArray(coords) || coords.length < 2 || !coords.every(Number.isFinite)) return false;
      if (!this.coordsWithinHallMaxBounds(coords)) return false;
      this._geoFitPending = false;
      this.map.easeTo({
        center: coords,
        zoom: Math.max(this.map.getZoom() || 0, 15.5),
        duration
      });
      return true;
    },

    coordsWithinHallMaxBounds(coords) {
      const maxBounds = this.hallMaxBounds();
      if (!maxBounds) return true;
      const [[west, south], [east, north]] = maxBounds;
      const [lon, lat] = coords;
      return lon >= west && lon <= east && lat >= south && lat <= north;
    },

    bindMapLayerEvents(layerId) {
      if (!this.map?.getLayer(layerId) || this._boundMapLayers.has(layerId)) return;
      this._boundMapLayers.add(layerId);
      this.map.on('click', layerId, (e) => this.onMapPointClick(e));
      this.map.on('mousemove', layerId, (e) => {
        this.map.getCanvas().style.cursor = 'pointer';
        this.hoveredId = e.features[0]?.properties?.external_id;
      });
      this.map.on('mouseleave', layerId, () => {
        this.map.getCanvas().style.cursor = '';
        this.hoveredId = null;
      });
    },

    async onMapPointClick(e) {
      const feature = e.features[0] || {};
      const props = feature.properties || {};
      const id = props.external_id;
      if (!id) return;
      let row = this.rows.find(r => r.external_id === id);
      if (!row && props._source_scope && props._source_name) {
        const qs = new URLSearchParams({ hall: this.hall });
        const r = await fetch(`/api/records/${props._source_scope}/${props._source_name}/${encodeURIComponent(id)}?${qs}`);
        if (r.ok) row = await r.json();
      }
      if (!row) row = props;
      if (row) {
        this.select({
          ...props,
          ...row,
          geometry: row.geometry || feature.geometry,
          _record_class: row._record_class || props._record_class,
          _source_scope: row._source_scope || props._source_scope,
          _source_name: row._source_name || props._source_name,
          _source_slug: row._source_slug || [props._source_scope, props._source_name].filter(Boolean).join('/')
        }, { source: 'map' });
        if (this.isMobileViewport() && !this.isParkingRecord(row)) this.mobileListOpen = true;
      }
    },

    rowIsHovered(row) {
      return this.hoveredId && row.external_id === this.hoveredId;
    },

    mergeStreamRow(row) {
      const key = row.external_id;
      const merged = [row, ...this.rows.filter(r => r.external_id !== key)];
      merged.sort((a, b) => {
        const ta = this.rowTimeMillis(a);
        const tb = this.rowTimeMillis(b);
        return tb - ta;
      });
      this.rows = merged.slice(0, MUNI_QUERY_LIMIT);
    },

    attachStream() {
      if (this.eventSource) { this.eventSource.close(); this.eventSource = null; }
      const es = new EventSource(`/stream/category/${encodeURIComponent(this.category)}?hall=${this.hall}`);
      es.onmessage = (ev) => {
        try {
          const row = JSON.parse(ev.data);
          this.mergeStreamRow(row);
          this.scheduleGeoRefresh();
        } catch (_) { /* ignore */ }
      };
      this.eventSource = es;
    },

    relativeTime(row) {
      void this.timeTick;
      if (this.typeHint(row) === 'FoodTruck' && row.weekday) return row.weekday;
      const ts = this.rowTimeValue(row);
      if (!ts) return '';
      const d = this.parseDate(ts);
      const diff = (Date.now() - d.getTime()) / 1000;
      if (isNaN(diff)) return '';
      if (diff < -60) return this.formatDateTime(ts);
      if (diff < 60) return 'just now';
      if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
      if (diff < 86400) return `${Math.round(diff / 3600)} h ago`;
      return d.toLocaleString();
    },

    shortDate(value) {
      const d = this.parseDate(value);
      if (isNaN(d.getTime())) return '';
      return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    },

    formatDateTime(value) {
      const d = this.parseDate(value);
      if (isNaN(d.getTime())) return value;
      return d.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
    },

    parseDate(value) {
      if (value instanceof Date) return value;
      if (typeof value !== 'string') return new Date(value);
      const text = value.trim()
        .replace(' UTC', 'Z')
        .replace(/^(\d{4}-\d{2}-\d{2}) /, '$1T')
        .replace(/(\.\d{3})\d+(?=Z|[+-]\d{2}:?\d{2}|$)/, '$1');
      return new Date(text);
    },

    calendarWeekdays() {
      return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    },

    eventsCalendarTitle() {
      void this.timeTick;
      const today = new Date();
      return today.toLocaleDateString([], { month: 'long', year: 'numeric' });
    },

    eventsActiveSummary() {
      void this.timeTick;
      const now = new Date();
      const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
      const tomorrowStart = new Date(todayStart);
      tomorrowStart.setDate(todayStart.getDate() + 1);
      const weekEnd = new Date(todayStart);
      weekEnd.setDate(todayStart.getDate() + (6 - todayStart.getDay()));
      weekEnd.setHours(23, 59, 59, 999);
      return (this.rows || []).reduce((counts, row) => {
        const date = this.eventStartDate(row);
        if (!date || isNaN(date.getTime())) return counts;
        if (date >= todayStart && date < tomorrowStart) counts.today += 1;
        if (date >= tomorrowStart && date <= weekEnd) counts.upcomingThisWeek += 1;
        return counts;
      }, { today: 0, upcomingThisWeek: 0 });
    },

    eventsCalendarDays() {
      void this.timeTick;
      const today = new Date();
      const first = new Date(today.getFullYear(), today.getMonth(), 1);
      const last = new Date(today.getFullYear(), today.getMonth() + 1, 0);
      const cells = [];

      for (let i = 0; i < first.getDay(); i++) {
        cells.push({ key: `blank-start-${i}`, blank: true });
      }
      for (let day = 1; day <= last.getDate(); day++) {
        const date = new Date(today.getFullYear(), today.getMonth(), day);
        const events = this.eventsForCalendarDate(date);
        const timing = this.eventTimingFromDate(date);
        cells.push({
          key: this.calendarDateKey(date),
          blank: false,
          label: String(day),
          accessibleLabel: this.eventDayLabel(date),
          today: this.calendarDateKey(date) === this.calendarDateKey(today),
          timing: events.length > 0 || this.calendarDateKey(date) === this.calendarDateKey(today) ? timing : '',
          events
        });
      }
      while (cells.length % 7 !== 0) {
        cells.push({ key: `blank-end-${cells.length}`, blank: true });
      }
      return cells;
    },

    eventsForCalendarDate(date) {
      const key = this.calendarDateKey(date);
      return this.rows.filter((row) => this.calendarDateKey(this.eventStartDate(row)) === key);
    },

    eventStartDate(row) {
      const raw = row?.event_start_at || row?.published_at || row?.updated_at;
      return raw ? this.parseDate(raw) : null;
    },

    calendarDateKey(date) {
      if (!date || isNaN(date.getTime())) return '';
      return [
        date.getFullYear(),
        String(date.getMonth() + 1).padStart(2, '0'),
        String(date.getDate()).padStart(2, '0')
      ].join('-');
    },

    eventDayLabel(date) {
      if (!date || isNaN(date.getTime())) return 'Date TBA';
      return date.toLocaleDateString([], { weekday: 'long', month: 'short', day: 'numeric' });
    },

    eventDaySublabel(date) {
      if (!date || isNaN(date.getTime())) return 'Unscheduled';
      const today = new Date();
      const tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1);
      if (this.calendarDateKey(date) === this.calendarDateKey(today)) return 'Today';
      if (this.calendarDateKey(date) === this.calendarDateKey(tomorrow)) return 'Tomorrow';
      return date.toLocaleDateString([], { month: 'long', year: 'numeric' });
    },

    eventCalendarTime(row) {
      if (this.eventAllDay(row)) return 'All day';
      const date = this.eventStartDate(row);
      if (!date || isNaN(date.getTime())) return '';
      return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    },

    eventAllDay(row) {
      const metadata = row?.metadata;
      if (metadata && typeof metadata === 'object') return Boolean(metadata.all_day || metadata.allDay);
      return false;
    },

    eventEndDate(row) {
      const raw = row?.event_end_at;
      return raw ? this.parseDate(raw) : null;
    },

    eventDateParts(row) {
      const date = this.eventStartDate(row);
      if (!date || isNaN(date.getTime())) return { month: '', day: '', weekday: '' };
      return {
        month: date.toLocaleDateString([], { month: 'short' }),
        day: String(date.getDate()),
        weekday: date.toLocaleDateString([], { weekday: 'short' })
      };
    },

    eventTimeRange(row) {
      const start = this.eventStartDate(row);
      if (!start || isNaN(start.getTime())) return 'Time TBA';
      const dateLabel = start.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
      if (this.eventAllDay(row)) return `${dateLabel}, all day`;

      const startTime = start.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      const end = this.eventEndDate(row);
      if (!end || isNaN(end.getTime())) return `${dateLabel}, ${startTime}`;

      const endTime = end.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      if (this.calendarDateKey(start) === this.calendarDateKey(end)) return `${dateLabel}, ${startTime} to ${endTime}`;

      const endLabel = end.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
      return `${dateLabel}, ${startTime} to ${endLabel}, ${endTime}`;
    },

    eventDurationLabel(row) {
      if (this.eventAllDay(row)) return 'All day';
      const start = this.eventStartDate(row);
      const end = this.eventEndDate(row);
      if (!start || !end || isNaN(start.getTime()) || isNaN(end.getTime())) return this.eventCalendarTime(row) || 'Time TBA';
      const minutes = Math.max(0, Math.round((end.getTime() - start.getTime()) / 60000));
      if (!minutes) return this.eventCalendarTime(row) || 'Time TBA';
      if (minutes < 60) return `${minutes} min`;
      const hours = Math.floor(minutes / 60);
      const remainder = minutes % 60;
      return remainder ? `${hours} hr ${remainder} min` : `${hours} hr`;
    },

    eventLocation(row) {
      return row?.location_name || row?.address || row?.neighborhood || 'Location TBA';
    },

    eventSourceLabel(row) {
      return row?.source_name || row?._source_slug || 'Official source';
    },

    eventCategoryLabel(row) {
      const raw = row?.category || '';
      return raw.toString().replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    },

    eventSummary(row) {
      return row?.summary || row?.description || '';
    },

    eventTags(row) {
      const raw = row?.tags;
      const values = Array.isArray(raw) ? raw : String(raw || '').split(',');
      return [...new Set(values.map(tag => tag.toString().trim()).filter(Boolean))].slice(0, 5);
    },

    eventUrl(row) {
      return row?.url || row?.source_url || '';
    },

    eventSourceHost(row) {
      const url = this.eventUrl(row);
      if (!url) return this.eventSourceLabel(row);
      try {
        return new URL(url, window.location.origin).hostname.replace(/^www\./, '');
      } catch (_) {
        return this.eventSourceLabel(row);
      }
    },

    eventImageUrl(row) {
      const metadata = row?.metadata;
      if (metadata && typeof metadata === 'object') return metadata.image_url || metadata.imageUrl || '';
      return row?.image_url || '';
    },

    rowTimeFields(row) {
      switch (this.typeHint(row)) {
        case 'ServiceRequest':
          return ['reported_at', 'opened_at', 'updated_at', 'closed_at'];
        case 'PoliceLogEntry':
        case 'CrimeReport':
          return ['reported_at', 'occurred_at'];
        case 'DispatchCall':
          return ['received_at', 'closed_at'];
        case 'Crash':
        case 'CpdCrash':
          return ['occurred_at'];
        case 'DigestItem':
          return ['event_start_at', 'published_at', 'updated_at', 'fetched_at'];
        default:
          return [
            'opened_at', 'reported_at', 'received_at', 'occurred_at',
            'starts_at', 'observed_at', 'updated_at', 'issued_at',
            'applied_at', 'published_at', 'closed_at', 'collected_at'
          ];
      }
    },

    rowTimeValue(row) {
      if (!row) return null;
      const fields = this.rowTimeFields(row);
      for (const field of fields) {
        if (row[field]) return row[field];
      }
      return null;
    },

    rowTimeMillis(row) {
      const value = this.rowTimeValue(row);
      const time = value ? this.parseDate(value).getTime() : 0;
      return Number.isFinite(time) ? time : 0;
    },

    formatMoney(value, { allowZero = false } = {}) {
      const amount = Number(value);
      if (!Number.isFinite(amount) || amount < 0 || (!allowZero && amount === 0)) return null;
      return amount.toLocaleString([], { style: 'currency', currency: 'USD', minimumFractionDigits: amount % 1 === 0 ? 0 : 2, maximumFractionDigits: 2 });
    },

    formatDiameter(value) {
      const diameter = Number(value);
      if (!Number.isFinite(diameter) || diameter <= 0) return null;
      return `${diameter.toFixed(1)} in`;
    },

    formatMinutes(value) {
      const minutes = Number(value);
      if (!Number.isFinite(minutes) || minutes <= 0) return null;
      if (minutes % 60 === 0) {
        const hours = minutes / 60;
        return `${hours} ${hours === 1 ? 'hour' : 'hours'}`;
      }
      return `${minutes} min`;
    },

    hasScientificName(row) {
      const value = row?.species_scientific;
      if (!value || value === row?.species_common) return false;
      const common = (row?.species_common || '').toString().toLowerCase();
      if (['retired', 'stump', 'planting site', 'proposed tree'].includes(common)) return false;
      return true;
    },

    highlight(row) {
      if (!this.map || this.defaultWidget !== 'map') return;
      const coords = this.recordAnchorCoords(row);
      if (!coords) return;
      const parking = this.isParkingRecord(row);
      this.map.flyTo({
        center: coords,
        zoom: parking ? Math.max(this.map.getZoom() || 0, 17.4) : 14,
        speed: parking ? 0.55 : 0.8,
        offset: parking ? this.selectionCameraOffset() : [0, 0]
      });
    },

    selectionCameraOffset() {
      if (this.isMobileViewport()) return [0, -90];
      return [-150, 0];
    },

    recordAnchorCoords(row) {
      const fromLocation = this.coordsFromValue(row?.location);
      if (fromLocation) return fromLocation;
      const coords = this.geometryCoordinates(this.geometryFromValue(row?.geometry));
      if (!coords.length) return null;
      const sum = coords.reduce((memo, [lon, lat]) => {
        memo.lon += lon;
        memo.lat += lat;
        return memo;
      }, { lon: 0, lat: 0 });
      return [sum.lon / coords.length, sum.lat / coords.length];
    },

    coordsFromValue(value) {
      if (Array.isArray(value) && value.length >= 2) {
        const lon = Number(value[0]);
        const lat = Number(value[1]);
        return Number.isFinite(lon) && Number.isFinite(lat) ? [lon, lat] : null;
      }
      if (typeof value === 'string') {
        try { return this.coordsFromValue(JSON.parse(value)); } catch (_) { return null; }
      }
      return null;
    },

    geometryFromValue(value) {
      if (!value) return null;
      if (typeof value === 'string') {
        try { return JSON.parse(value); } catch (_) { return null; }
      }
      return value;
    },

    railKeydown(e) {
      const buttons = [...this.$refs.rail?.querySelectorAll('.rail__btn:not(:disabled), .rail__sub-btn:not(:disabled)') || []]
        .filter((button) => button.getClientRects().length > 0 && getComputedStyle(button).visibility !== 'hidden');
      const idx = buttons.indexOf(document.activeElement);
      if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
        e.preventDefault();
        const next = buttons[Math.min(idx + 1, buttons.length - 1)] || buttons[0];
        next?.focus();
      } else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
        e.preventDefault();
        const prev = buttons[Math.max(idx - 1, 0)] || buttons[buttons.length - 1];
        prev?.focus();
      } else if (e.key === 'Enter') {
        if (document.activeElement?.classList.contains('rail__btn') ||
            document.activeElement?.classList.contains('rail__sub-btn')) {
          document.activeElement.click();
        }
      }
    },

    focusActiveRail() {
      const btn = this.$refs.rail?.querySelector('.rail__btn.is-active');
      btn?.focus();
    },

    isMobileViewport() {
      return window.matchMedia?.('(max-width: 639px)').matches || window.innerWidth < 640;
    },

    toggleMobileList() {
      this.mobileListOpen = !this.mobileListOpen;
      this.$nextTick(() => this.resizeMap());
    }
  };
};

window.muniDashboard = function ({ hall }) {
  return {
    hall,
    payload: { widgets: {} },
    loading: true,

    async init() {
      await this.load();
    },

    async load() {
      this.loading = true;
      try {
        const response = await fetch(`/api/dashboard?hall=${encodeURIComponent(this.hall)}`);
        this.payload = response.ok ? await response.json() : { widgets: {} };
      } catch (_) {
        this.payload = { widgets: {} };
      } finally {
        this.loading = false;
      }
    },

    widget(name) {
      return this.payload?.widgets?.[name] || {};
    },

    analytics(name) {
      return this.payload?.analytics?.[name] || {};
    },

    signals() {
      return Array.isArray(this.payload?.signals) ? this.payload.signals : [];
    },

    signalTone(signal) {
      const tone = signal?.tone || 'neutral';
      return ['amber', 'blue', 'green', 'neutral', 'rose'].includes(tone) ? tone : 'neutral';
    },

    signalValue(signal) {
      const riskBand = this.signalRiskBand(signal);
      if (riskBand) return riskBand;

      const metric = signal?.metric;
      const label = signal?.metric_label;
      if (metric === undefined || metric === null || metric === '') return '';
      return label ? `${metric} ${label}` : String(metric);
    },

    signalIsRiskMetric(signal) {
      const metricLabel = String(signal?.metric_label || '').toLowerCase();
      if (['risk', 'score'].includes(metricLabel)) return true;

      const text = [
        signal?.id,
        signal?.title,
        signal?.headline
      ].filter(Boolean).join(' ').toLowerCase();
      return text.includes('risk') || text.includes('hotspot');
    },

    signalRiskBand(signal) {
      if (!this.signalIsRiskMetric(signal)) return '';

      const rawMetric = String(signal?.metric ?? '').replace(/,/g, '').trim();
      const value = Number(rawMetric);
      const fallback = this.signalTone(signal) === 'rose'
        ? 'HIGH'
        : this.signalTone(signal) === 'amber'
          ? 'MED'
          : 'LOW';
      return this.riskTierLabel(Number.isFinite(value) ? value : null, fallback);
    },

    riskTier(value, fallback = 'LOW') {
      if (value === null || value === undefined || value === '') return fallback;
      const score = Number(value);
      if (!Number.isFinite(score)) return fallback;
      if (score >= 67) return 'HIGH';
      if (score >= 34) return 'MED';
      return 'LOW';
    },

    riskTierLabel(value, fallback = 'LOW') {
      return `${this.riskTier(value, fallback)} RISK`;
    },

    signalMeta(signal) {
      if (signal?.context) return signal.context;
      const parts = [];
      const windowDays = Number(signal?.window_days);
      const sampleSize = Number(signal?.sample_size);
      if (Number.isFinite(windowDays) && windowDays > 0) parts.push(`${this.num(windowDays)}d window`);
      if (Number.isFinite(sampleSize) && sampleSize > 0) {
        parts.push(`${this.num(sampleSize)} ${signal?.sample_label || 'samples'}`);
      }
      return parts.join(' / ');
    },

    signalsFreshness() {
      const times = this.signals()
        .map((signal) => new Date(signal.generated_at || signal.source_at))
        .filter((date) => !isNaN(date.getTime()));
      if (times.length === 0) return 'cached';
      const latest = new Date(Math.max(...times.map((date) => date.getTime())));
      return `updated ${this.relativeAge(latest)}`;
    },

    num(value) {
      const n = Number(value);
      if (!Number.isFinite(n)) return '0';
      return n.toLocaleString();
    },

    days(value) {
      const n = Number(value);
      if (!Number.isFinite(n) || n <= 0) return 'n/a';
      if (n < 1) return `${Math.round(n * 24)}h`;
      return `${n.toLocaleString(undefined, { maximumFractionDigits: 1 })}d`;
    },

    duration(seconds) {
      const n = Number(seconds);
      if (!Number.isFinite(n) || n <= 0) return 'n/a';
      const hours = n / 3600;
      if (hours < 1) return `${Math.round(n / 60)}m`;
      if (hours < 24) return `${Math.round(hours)}h`;
      return `${Math.round(hours / 24)}d`;
    },

    trendSeries(points) {
      return Array.isArray(points) ? points : [];
    },

    trendValue(point) {
      const value = Number(point?.value);
      return Number.isFinite(value) ? value : null;
    },

    trendMax(points) {
      const values = this.trendSeries(points)
        .map((point) => this.trendValue(point))
        .filter((value) => value !== null && value > 0);
      return Math.max(...values, 1);
    },

    sumTrend(points) {
      return this.trendSeries(points).reduce((sum, point) => sum + (this.trendValue(point) || 0), 0);
    },

    lastTrendValue(points) {
      const series = this.trendSeries(points);
      const point = [...series].reverse().find((entry) => {
        const value = this.trendValue(entry);
        return value !== null && value > 0;
      });
      return this.trendValue(point) || 0;
    },

    barPercent(point, points) {
      const value = this.trendValue(point);
      if (value === null) return 0;
      if (value <= 0) return 4;
      return Math.max(10, Math.round((value / this.trendMax(points)) * 100));
    },

    trendPoints(points) {
      const series = this.trendSeries(points);
      if (series.length === 0) return '';

      const max = this.trendMax(series);
      const last = series.length - 1;
      return series.map((point, index) => {
        const value = this.trendValue(point);
        if (value === null) return null;
        const x = last === 0 ? 50 : (index / last) * 100;
        const y = 36 - ((value / max) * 30);
        return `${x.toFixed(2)},${y.toFixed(2)}`;
      }).filter(Boolean).join(' ');
    },

    trendValueLabel(point, format = 'number') {
      const value = Number(point?.value);
      if (!Number.isFinite(value) || value <= 0) return 'no data';
      if (format === 'duration') return this.duration(value);
      return this.num(value);
    },

    trendScope(points) {
      const series = this.trendSeries(points);
      if (series.length === 0) return 'awaiting source data';

      const last = series[series.length - 1]?.label;
      return last ? `through ${last}` : 'source-covered';
    },

    trendLabel(name, points, format = 'number') {
      const series = this.trendSeries(points);
      if (series.length === 0) return `${name}: no recent data`;

      const first = series[0]?.label || 'start';
      const last = series[series.length - 1]?.label || 'today';
      const value = format === 'duration'
        ? this.duration(this.lastTrendValue(series))
        : this.num(this.sumTrend(series));
      return `${name}: ${value} from ${first} to ${last}`;
    },

    take(items, limit) {
      return Array.isArray(items) ? items.slice(0, limit) : [];
    },

    sharePercent(item, items) {
      const value = Number(item?.count) || 0;
      const max = Math.max(...this.take(items, 12).map((row) => Number(row?.count) || 0), 1);
      if (value <= 0) return 0;
      return Math.max(12, Math.round((value / max) * 100));
    },

    heatAlpha(item, items) {
      const value = Number(item?.count) || 0;
      const max = Math.max(...this.take(items, 24).map((row) => Number(row?.count) || 0), 1);
      if (value <= 0) return '0.06';
      const alpha = 0.1 + ((value / max) * 0.34);
      return alpha.toFixed(3);
    },

    scoreRows(items) {
      return Array.isArray(items)
        ? items.map((item) => ({ ...item, count: Number(item.score) || 0 }))
        : [];
    },

    analyticsScope(model) {
      if (!model || model.status === 'warming') return 'warming';
      const generated = model.generated_at;
      return generated ? `updated ${this.relativeAge(generated)}` : 'cached';
    },

    riskNote() {
      const model = this.analytics('crash_risks');
      if (!model || model.status === 'warming') return 'Risk cache is warming.';
      const locations = model.locations || [];
      if (locations.length === 0) return 'No ranked crash locations yet.';
      return 'Weighted by recency and vulnerable-road-user involvement.';
    },

    anomalyNote() {
      const model = this.analytics('service_request_anomalies');
      if (!model || model.status === 'warming') return 'Anomaly cache is warming.';
      const anomalies = model.anomalies || [];
      if (anomalies.length === 0) return 'No current case-type spikes detected.';
      return 'Compared with source-covered weekly baselines.';
    },

    sources() {
      return Array.isArray(this.payload?.sources) ? this.payload.sources : [];
    },

    featuredSources() {
      const order = ['service_requests', 'police', 'crashes', 'permits'];
      return order.map((category) => this.sources().find((source) => source.category === category)).filter(Boolean);
    },

    sourceFreshness(source) {
      const parts = [];
      if (source?.cadence) parts.push(`every ${source.cadence}`);
      const latest = source?.last_seen_at || source?.last_success_at || source?.last_run_at;
      if (latest) parts.push(`latest ${this.relativeAge(latest)}`);
      if (source?.last_error) parts.push('last run errored');
      return parts.join(' / ') || 'awaiting collection';
    },

    signalPath(signal) {
      if (!signal?.category) return '#';
      const qs = new URLSearchParams({ hall: this.hall, category: signal.category });
      if (signal.time_range) qs.set('time_range', signal.time_range);
      return `/?${qs.toString()}`;
    },

    relativeAge(value) {
      const d = new Date(value);
      if (isNaN(d.getTime())) return 'unknown';
      const diff = Math.max(0, (Date.now() - d.getTime()) / 1000);
      if (diff < 60) return 'just now';
      if (diff < 3600) return `${Math.round(diff / 60)}m ago`;
      if (diff < 86400) return `${Math.round(diff / 3600)}h ago`;
      return `${Math.round(diff / 86400)}d ago`;
    },

    evidencePath(category) {
      const ranges = {
        service_requests: '30d',
        police: '14d',
        permits: '30d',
        crashes: '90d'
      };
      const qs = new URLSearchParams({ hall: this.hall, category });
      const range = ranges[category];
      if (range) qs.set('time_range', range);
      return `/?${qs.toString()}`;
    }
  };
};

window.muniDigest = function ({ hall, hallName }) {
  return {
    hall,
    payload: { cards: [] },
    loading: true,
    activeCard: null,
    _dailyRefreshTimer: null,

    async init() {
      await this.load();
      this.scheduleDailyRefresh();
    },

    async load() {
      this.loading = true;
      try {
        const response = await fetch(`/api/digest?hall=${encodeURIComponent(this.hall)}`);
        this.payload = response.ok ? await response.json() : { cards: [] };
      } catch (_) {
        this.payload = { cards: [] };
      } finally {
        this.loading = false;
      }
    },

    scheduleDailyRefresh() {
      if (this._dailyRefreshTimer) clearInterval(this._dailyRefreshTimer);
      this._dailyRefreshTimer = setInterval(() => this.load(), 24 * 60 * 60 * 1000);
    },

    cards() {
      const cards = Array.isArray(this.payload?.cards) ? this.payload.cards : [];
      return [...cards].sort((a, b) => Number(a?.priority || 0) - Number(b?.priority || 0));
    },

    leadCard() {
      return this.cards()[0] || null;
    },

    secondaryCards() {
      return this.cards().slice(1);
    },

    openCard(card) {
      if (!card) return;
      this.activeCard = card;
    },

    closeCard() {
      this.activeCard = null;
    },

    footnotes() {
      return Array.isArray(this.payload?.footnotes) ? this.payload.footnotes : [];
    },

    titleLabel() {
      return 'Digest';
    },

    cardTone(card) {
      const tone = card?.tone || 'neutral';
      return ['blue', 'green', 'amber', 'rose', 'neutral'].includes(tone) ? tone : 'neutral';
    },

    editionMeta() {
      const edition = this.payload?.edition_label || hallName || 'Muni';
      const generated = this.payload?.generated_at ? `updated ${this.relativeAge(this.payload.generated_at)}` : 'warming';
      return `${edition} / ${generated}`;
    },

    warmingText() {
      return this.payload?.status === 'warming'
        ? `The next cached edition is warming from public ${hallName || 'city'} sources.`
        : 'No digest cards are available yet.';
    },

    metricLine(card) {
      const metric = card?.metric || {};
      const line = [metric.label, metric.sublabel].filter(Boolean).join(' / ');
      return line || this.cardDate(card) || this.sourceTypeLabel(card?.source_type);
    },

    sourceChip(card) {
      if (card?.source_type === 'trend_data_signal') {
        return this.signalChip(card);
      }
      return this.sourceTypeLabel(card?.source_type);
    },

    signalChip(card) {
      if (this.cardLooksRisky(card)) {
        return this.riskTierLabel(card?.metric?.value || card?.visual?.value, card?.tone);
      }
      return this.sourceTypeLabel(card?.source_type);
    },

    sourceTypeLabel(type) {
      return {
        official_record: 'Official',
        press_report: 'Press',
        event_listing: 'Event',
        trend_data_signal: 'Trend',
        model_inference: 'Inference'
      }[type] || 'Source';
    },

    cardLooksRisky(card) {
      const text = [
        card?.id,
        card?.category,
        card?.metric?.label,
        card?.visual?.label,
        card?.title
      ].filter(Boolean).join(' ').toLowerCase();
      return text.includes('risk') || text.includes('hotspot');
    },

    riskTierLabel(value, tone) {
      const fallback = tone === 'rose' ? 'HIGH' : tone === 'amber' ? 'MED' : 'LOW';
      const score = Number(String(value ?? '').replace(/,/g, '').trim());
      const tier = Number.isFinite(score)
        ? score >= 67
          ? 'HIGH'
          : score >= 34
            ? 'MED'
            : 'LOW'
        : fallback;
      return `${tier} RISK`;
    },

    showVisual(card) {
      const type = card?.visual?.type;
      return Boolean(type && type !== 'source_badge');
    },

    cardSourceName(card) {
      const source = card?.sources?.[0]?.name || card?.visual?.source || '';
      const type = this.sourceTypeLabel(card?.source_type);
      return source && source !== type ? source : '';
    },

    cardDate(card) {
      const value = card?.event_start_at || card?.published_at || card?.sources?.[0]?.published_at || card?.visual?.date;
      if (!value) return '';
      const date = new Date(value);
      if (isNaN(date.getTime())) return '';
      return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    },

    detailMeta(card) {
      return [card?.section, this.sourceTypeLabel(card?.source_type), this.cardDate(card)]
        .filter(Boolean)
        .join(' / ');
    },

    detailHref(card) {
      return card?.href || card?.sources?.[0]?.url || '#';
    },

    detailActionLabel(card) {
      return card?.source_type === 'trend_data_signal' ? 'Open in Trends' : 'Official source';
    },

    visualSource(card) {
      return card?.visual?.source || card?.sources?.[0]?.name || this.sourceTypeLabel(card?.source_type);
    },

    visualDate(card) {
      const value = card?.visual?.date || card?.event_start_at || card?.published_at;
      if (!value) return card?.visual?.location || '';
      const date = new Date(value);
      if (isNaN(date.getTime())) return '';
      return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    },

    visualType(card, type) {
      return card?.visual?.type === type;
    },

    visualBadge(card) {
      return card?.visual?.badge || null;
    },

    visualPoints(card) {
      return Array.isArray(card?.visual?.points) ? card.visual.points : [];
    },

    visualStats(card) {
      return Array.isArray(card?.visual?.stats) ? card.visual.stats : [];
    },

    visualItems(card) {
      return Array.isArray(card?.visual?.items) ? card.visual.items : [];
    },

    value(point) {
      const value = Number(point?.value);
      return Number.isFinite(value) ? value : 0;
    },

    sparkMax(points) {
      return Math.max(...this.visualArray(points).map((point) => this.value(point)), 1);
    },

    sparkBar(point, points) {
      const value = this.value(point);
      if (value <= 0) return 4;
      return Math.max(10, Math.round((value / this.sparkMax(points)) * 100));
    },

    sparkPoints(points) {
      const series = this.visualArray(points);
      if (series.length === 0) return '';
      const max = this.sparkMax(series);
      const last = series.length - 1;
      return series.map((point, index) => {
        const x = last === 0 ? 50 : (index / last) * 100;
        const y = 30 - ((this.value(point) / max) * 24);
        return `${x.toFixed(2)},${y.toFixed(2)}`;
      }).join(' ');
    },

    visualArray(points) {
      return Array.isArray(points) ? points : [];
    },

    relativeAge(value) {
      const date = new Date(value);
      if (isNaN(date.getTime())) return 'unknown';
      const diff = Math.max(0, (Date.now() - date.getTime()) / 1000);
      if (diff < 60) return 'just now';
      if (diff < 3600) return `${Math.round(diff / 60)}m ago`;
      if (diff < 86400) return `${Math.round(diff / 3600)}h ago`;
      return `${Math.round(diff / 86400)}d ago`;
    }
  };
};

window.muniMeetings = function ({ hall }) {
  return {
    hall,
    rows: [],
    loading: true,
    activeMeeting: null,

    async init() {
      await this.load();
    },

    async load() {
      this.loading = true;
      try {
        const response = await fetch(`/api/meetings?hall=${encodeURIComponent(this.hall)}`);
        const data = response.ok ? await response.json() : [];
        this.rows = Array.isArray(data) ? data : [];
      } catch (_) {
        this.rows = [];
      } finally {
        this.loading = false;
      }
    },

    meetings() {
      return this.rows;
    },

    openMeeting(meeting) {
      if (meeting) this.activeMeeting = meeting;
    },

    closeMeeting() {
      this.activeMeeting = null;
    },

    hasSummary(meeting) {
      return !!(meeting && meeting.ai_summary && String(meeting.ai_summary).trim());
    },

    brief(meeting) {
      if (!meeting) return '';
      const summary = this.hasSummary(meeting) ? String(meeting.ai_summary) : '';
      if (summary) return summary.length > 180 ? `${summary.slice(0, 177)}…` : summary;
      const topics = this.topics(meeting);
      return topics.length ? topics.join(' · ') : 'Agenda and video are available.';
    },

    topics(meeting) {
      return Array.isArray(meeting?.key_topics) ? meeting.key_topics : [];
    },

    people(meeting) {
      return Array.isArray(meeting?.people) ? meeting.people : [];
    },

    summaryModelLabel(meeting) {
      return meeting?.summary_model ? `(${meeting.summary_model})` : '';
    },

    summaryKindLabel(meeting) {
      const kind = String(meeting?.source_text_kind || '');
      if (kind === 'agenda' || kind === 'packet') return 'Agenda preview';
      return 'Meeting summary';
    },

    summarySourceLabel(meeting) {
      const labels = {
        agenda: 'agenda',
        packet: 'packet',
        final_actions: 'final actions',
        minutes: 'minutes',
        transcript: 'transcript'
      };
      return labels[String(meeting?.source_text_kind || '')] || meeting?.source_text_kind || '';
    },

    cardEyebrow(meeting) {
      if (!meeting) return '';
      return [meeting.body, this.fmtDate(meeting.meeting_at)].filter(Boolean).join(' · ');
    },

    fmtDate(value) {
      if (!value) return '';
      const date = new Date(value);
      if (isNaN(date.getTime())) return '';
      return date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    },

    fullDate(meeting) {
      if (!meeting?.meeting_at) return '';
      const date = new Date(meeting.meeting_at);
      if (isNaN(date.getTime())) return '';
      return date.toLocaleString(undefined, {
        year: 'numeric', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit',
      });
    },

    editionMeta() {
      const count = this.rows.length;
      return `${this.hall} · ${count} recent ${count === 1 ? 'meeting' : 'meetings'}`;
    },
  };
};
