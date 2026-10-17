module Muni
  module Beats
    MAX_SEED_PAGES = 100

    def self.run_all_once!(hall: nil, beats: nil)
      selected = beats || Muni::Registry.beats.values
      selected = selected.select { |klass| klass.slug.start_with?("#{hall}/") } if hall
      Muni::Beat.ordered(selected).map do |klass|
        result = run_to_seed_completion(klass)
        {
          slug:          klass.slug,
          rows_in:       result[:rows_in],
          rows_upserted: result[:rows_upserted],
          error:         seed_error_message(result[:error])
        }
      end
    end

    def self.run_to_seed_completion(klass)
      total = { rows_in: 0, rows_upserted: 0, error: nil }
      pages = 0

      loop do
        result = klass.new.run!
        total[:rows_in] += result[:rows_in]
        total[:rows_upserted] += result[:rows_upserted]
        total[:error] = result[:error]
        break if result[:error] || !offset_seed_incomplete?(klass)

        pages += 1
        if pages >= MAX_SEED_PAGES
          total[:error] = "seed exceeded #{MAX_SEED_PAGES} pages without completing its cursor"
          break
        end
      end

      total
    end

    def self.offset_seed_incomplete?(klass)
      klass.cursor == :offset && Muni::Store.meta("cursor:offset:#{klass.slug}").to_i.positive?
    end

    def self.seed_error_message(error)
      error.respond_to?(:message) ? error.message : error
    end
  end
end
