module Muni
  module Get
    # Canonical map of launch collector domains → providers → sources/records.
    # View categories and MCP tools should derive from here when possible.
    # rubocop:disable-next Metrics/ModuleLength
    module Registry
      P = Provider

      DOMAINS = [
        Domain.new(
          slug:          :'311',
          title:         '311 service requests',
          aliases:       [],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/service_requests',
                             record_slug: 'service_requests')
          }
        ),
        Domain.new(
          slug:          :police,
          title:         'Police daily log',
          aliases:       [],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/police_log', record_slug: 'police_log_entrys')
          }
        ),
        Domain.new(
          slug:          :crime_reports,
          title:         'Crime reports',
          aliases:       %w[crime],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/crime_reports',
                             record_slug: 'crime_reports')
          }
        ),
        Domain.new(
          slug:          :dispatch_calls,
          title:         'Computer aided dispatch',
          aliases:       %w[dispatch cad fire],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/dispatch_calls',
                             record_slug: 'dispatch_calls')
          }
        ),
        Domain.new(
          slug:          :permits,
          title:         'Building permits',
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/building_permits',
                             record_slug: 'building_permits')
          }
        ),
        Domain.new(
          slug:          :crashes,
          title:         'Collisions',
          aliases:       [],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/vision_zero_crashes', record_slug: 'crashs')
          }
        ),
        Domain.new(
          slug:          :recent_crashes,
          title:         'Recent collision log',
          aliases:       %w[cpd-crashes cpd_crashes],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/cpd_crash_log', record_slug: 'cpd_crashs')
          }
        ),
        Domain.new(
          slug:          :traffic_volume,
          title:         'Traffic volume',
          aliases:       %w[traffic miovision],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/traffic_volume_daily',
                             record_slug: 'traffic_volume_dailys')
          }
        ),
        Domain.new(
          slug:          :bicycle_counts,
          title:         'Bicycle counts',
          aliases:       %w[bike-counts bikes],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/bicycle_counts',
                             record_slug: 'bicycle_counts')
          }
        ),
        Domain.new(
          slug:          :pedestrian_counts,
          title:         'Pedestrian counts',
          aliases:       %w[ped-counts pedestrians],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/pedestrian_counts',
                             record_slug: 'pedestrian_count_dailys')
          }
        ),
        Domain.new(
          slug:          :parking,
          title:         'Metered parking spaces',
          aliases:       %w[meters metered-parking parking-meters],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/metered_parking_spaces',
                             record_slug: 'metered_parking_spaces')
          }
        ),
        Domain.new(
          slug:          :trees,
          title:         'Street trees',
          aliases:       [],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/tree_inventory', record_slug: 'trees')
          }
        ),
        Domain.new(
          slug:          :parks,
          title:         'Parks',
          aliases:       %w[open-space open_space],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/parks', record_slug: 'parks')
          }
        ),
        Domain.new(
          slug:          :food_trucks,
          title:         'Food trucks',
          aliases:       %w[food-trucks trucks],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/food_trucks',
                             record_slug: 'food_trucks')
          }
        ),
        Domain.new(
          slug:          :events,
          title:         'Official events',
          aliases:       %w[event tonight calendar],
          requires_zone: true,
          providers:     {
            cambridge:         P.new(
              key: :cambridge, source_slug: 'cambridge/city_calendar', record_slug: 'digest_items'
            ),
            cambridge_tourism: P.new(
              key: :cambridge_tourism, source_slug: 'cambridge/tourism_events', record_slug: 'digest_items'
            )
          }
        ),
        Domain.new(
          slug:          :new_construction,
          title:         'New construction permits',
          aliases:       %w[new-construction],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/new_construction_permits',
                             record_slug: 'new_construction_permits')
          }
        ),
        Domain.new(
          slug:          :developments,
          title:         'Development projects',
          aliases:       %w[development-log developments],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/development_log',
                             record_slug: 'development_projects')
          }
        ),
        Domain.new(
          slug:          :zoning_appeals,
          title:         'Board of Zoning Appeal requests',
          aliases:       %w[zoning bza],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/zoning_appeals',
                             record_slug: 'zoning_appeals')
          }
        ),
        Domain.new(
          slug:          :meetings,
          title:         'City Council & board meetings',
          aliases:       %w[meeting meetings townhall town-hall council],
          requires_zone: true,
          providers:     {
            cambridge: P.new(key: :cambridge, source_slug: 'cambridge/meetings', record_slug: 'meetings')
          }
        ),
        Domain.new(
          slug:          :transit,
          title:         'MBTA Rapid Transit & Commuter Rail',
          aliases:       %w[mbta trains subway],
          requires_zone: false,
          providers:     {}
        )
      ].freeze

      # Single manifest for web panes — beats and DOMAINS must cover every source_slug here.
      CATEGORIES = [
        { slug: :service_requests, section: '311', title: '311', icon: 'rss', default_widget: :map,
          source_slugs: %w[cambridge/service_requests],
          empty_message: 'No 311 reports yet' },
        { slug: :safety, section: 'Safety', title: 'Safety', icon: 'caution', default_widget: :map,
          source_slugs: %w[
            cambridge/police_log
            cambridge/crime_reports
            cambridge/dispatch_calls
            cambridge/cpd_crash_log
          ],
          empty_message: 'No safety records yet' },
        { slug: :police, section: 'Safety', title: 'Police', icon: 'badge', default_widget: :map,
          source_slugs: %w[cambridge/police_log],
          empty_message: 'No police log entries yet' },
        { slug: :crime_reports, section: 'Safety', title: 'Crime', icon: 'handcuffs', default_widget: :map,
          source_slugs: %w[cambridge/crime_reports],
          empty_message: 'No crime reports yet' },
        { slug: :dispatch_calls, section: 'Safety', title: 'Dispatch', icon: 'radio', default_widget: :map,
          source_slugs: %w[cambridge/dispatch_calls],
          empty_message: 'No dispatch calls yet' },
        { slug: :crashes, section: 'Safety', title: 'Collisions', icon: 'car-burst', default_widget: :map,
          source_slugs: %w[cambridge/vision_zero_crashes cambridge/cpd_crash_log],
          empty_message: 'No collision records yet' },
        { slug: :permits, section: 'Housing & Development', title: 'Permits', icon: 'paper', default_widget: :map,
          source_slugs: %w[cambridge/building_permits],
          empty_message: 'No building permits yet' },
        { slug: :developments, section: 'Housing & Development', title: 'Development', icon: 'hammer',
          default_widget: :map, source_slugs: %w[cambridge/new_construction_permits cambridge/development_log],
          empty_message: 'No development records yet' },
        { slug: :zoning_appeals, section: 'Housing & Development', title: 'Zoning Appeals', icon: 'badge',
          default_widget: :map, source_slugs: %w[cambridge/zoning_appeals],
          empty_message: 'No zoning appeals yet' },
        { slug: :parking, section: 'Parking', title: 'Parking', icon: 'parking', default_widget: :map,
          source_slugs: %w[cambridge/metered_parking_spaces],
          empty_message: 'No metered parking spaces yet' },
        { slug: :environment, section: 'Environment', title: 'Environment', icon: 'leaf', default_widget: :map,
          source_slugs: %w[cambridge/tree_inventory cambridge/parks],
          empty_message: 'No environment records yet' },
        { slug: :trees, section: 'Environment', title: 'Trees', icon: 'tree-pine', default_widget: :map,
          source_slugs: %w[cambridge/tree_inventory],
          empty_message: 'No street trees yet' },
        { slug: :parks, section: 'Environment', title: 'Parks', icon: 'map', default_widget: :map,
          source_slugs: %w[cambridge/parks],
          empty_message: 'No park polygons yet' },
        { slug: :food_trucks, section: 'Food Trucks', title: 'Food trucks', icon: 'truck', default_widget: :map,
          source_slugs: %w[cambridge/food_trucks],
          empty_message: 'No food truck schedules yet' },
        { slug: :events, section: 'Events', title: 'Events', icon: 'calendar', default_widget: :list,
          source_slugs: %w[cambridge/city_calendar cambridge/tourism_events],
          empty_message: 'No official city events in this window.' },
        { slug: :transit, section: 'Mobility', title: 'Transit', icon: 'route', default_widget: :map,
          source_slugs: %w[],
          empty_message: 'No active transit alerts reported.' }
      ].freeze

      class << self
        def all
          DOMAINS.map do |domain|
            providers = domain.providers.merge(catalog_providers(domain.slug))
            Domain.new(**domain.to_h, providers: providers)
          end
        end

        def find(slug)
          key = slug.to_s.downcase.tr('-', '_').to_sym
          all.find { |d| d.slug == key } ||
            all.find { |d| d.aliases.map(&:to_s).include?(slug.to_s.downcase) }
        end

        def find!(slug)
          find(slug) or raise ArgumentError,
                              "unknown domain: #{slug} (try: #{all.map(&:slug).join(', ')})"
        end

        def slugs
          all.flat_map { |d| [d.slug.to_s, *d.aliases] }.uniq
        end

        def view_categories = CATEGORIES

        def category_source_slugs
          CATEGORIES.flat_map { |c| c[:source_slugs] }.concat(
            Muni::Registry.sources.values.select { |source| source.categories.any? }.map(&:slug)
          ).uniq
        end

        def domain_source_slugs
          all.flat_map { |d| d.providers.values.map(&:source_slug) }.uniq
        end

        private

        def provider_source(slug)
          d = find(slug)
          return [] unless d

          d.providers.values.map(&:source_slug)
        end

        def catalog_providers(domain_slug)
          Muni::Registry.sources.values.each_with_object({}) do |source, providers|
            key = source.domains[domain_slug.to_sym]
            next unless key

            providers[key] = P.new(key: key, source_slug: source.slug, record_slug: source.emits.slug)
          end
        end
      end
    end
  end
end
