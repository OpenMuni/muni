require 'muni/version'
require 'muni/logger'
require 'muni/registry'
require 'muni/config'
require 'muni/helpers/http'
require 'muni/helpers/geo'
require 'muni/helpers/normalize'
require 'muni/record'
require 'muni/store'
require 'muni/source'
require 'muni/beat'
require 'muni/beats_runner'
require 'muni/scheduler'
require 'muni/local_time'
require 'muni/water'
require 'muni/transit'
require 'muni/hall'
require 'muni/zone'
require 'muni/get/provider'
require 'muni/get/domain'
require 'muni/get/registry'
require 'muni/get/runner'
require 'muni/plat'
require 'muni/parking'
require 'muni/service_request_policy'
require 'muni/view'
require 'muni/display'
require 'muni/analytics'
require 'muni/dashboard'
require 'muni/status'
require 'muni/anthropic_client'
require 'muni/apps'
require 'muni/data'
require 'muni/data/parking_check'
require 'muni/command'

# Shared API clients reused across sources.
require 'muni/clients/socrata'
require 'muni/clients/arcgis'
require 'muni/clients/ckan'

# Record types ship with the framework. Each one self-registers on load.
require 'muni/records/service_request'
require 'muni/records/building_permit'
require 'muni/records/new_construction_permit'
require 'muni/records/development_project'
require 'muni/records/zoning_appeal'
require 'muni/records/police_log_entry'
require 'muni/records/crash'
require 'muni/records/tree'
require 'muni/records/park'
require 'muni/records/food_truck'
require 'muni/records/metered_parking_space'
require 'muni/records/crime_report'
require 'muni/records/dispatch_call'
require 'muni/records/cpd_crash'
require 'muni/records/traffic_volume_daily'
require 'muni/records/bicycle_count'
require 'muni/records/pedestrian_count_daily'
require 'muni/records/digest_item'
require 'muni/records/meeting'

# Meeting transcript/agenda summarizer (Claude). Loaded after records so it can
# reference Muni::Records::Meeting; pdf-reader is required lazily inside it.
require 'muni/meetings/summarizer'
require 'muni/meetings/primegov_materializer'

module Muni
  # Load every source/beat file under sources/ and core/lib/muni/beats/.
  # Called by the CLI/web entrypoints after `require 'muni'`.
  def self.boot!(root: Muni::Config.repo_root)
    Dir[File.join(__dir__, 'muni', 'beats', '*.rb')].each { |f| require f }
    Dir[File.join(root, 'sources', '**', '*.rb')].each { |f| require f }
    Muni::Water.register!
    Muni::Beat.register_catalog_beats!
    self
  end
end
