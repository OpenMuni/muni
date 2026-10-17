require 'muni/local_time'
require 'yaml'

module Muni
  Hall = Struct.new(:slug, :name, :timezone, :bbox, :center, :source_slugs, :boundary,
                    keyword_init: true) do
    def meetings_enabled?
      source_slugs.any? { |source| source.end_with?('/meetings', '/primegov_meetings') }
    end

    def capabilities
      {
        report:   false,
        meetings: meetings_enabled?,
        read:     true
      }
    end

    def public?
      configured = ENV.fetch('MUNI_PUBLIC_HALLS', '').split(',').map(&:strip).reject(&:empty?)
      configured.empty? || configured.include?(slug)
    end

    def to_h
      {
        slug: slug, name: name, timezone: timezone, bbox: bbox, center: center,
        sources: source_slugs, boundary: boundary, capabilities: capabilities
      }
    end

    class << self
      def load_all!(dir = Muni::Config.halls_dir)
        Muni::Registry.halls.each_key { |k| Muni::Registry.halls.delete(k) }
        Dir.glob(File.join(dir, '*.yml')).each { |path| load_file(path) }
        all
      end

      def load_file(path)
        data = YAML.load_file(path)['hall']
        hall = new(
          slug:         data['slug'],
          name:         data['name'],
          timezone:     data['timezone'] || Muni::LocalTime::DEFAULT_TIMEZONE,
          bbox:         data['bbox'],
          center:       data['center'],
          source_slugs: data['sources'] || [],
          boundary:     data['boundary']
        )
        Muni::Registry.register_hall(hall)
      end

      def find(slug)
        all_loaded? ? Muni::Registry.hall(slug) : (load_all! && Muni::Registry.hall(slug))
      end

      def all
        load_all! unless all_loaded?
        Muni::Registry.halls.values
      end

      def all_loaded?
        !Muni::Registry.halls.empty?
      end
    end
  end
end
