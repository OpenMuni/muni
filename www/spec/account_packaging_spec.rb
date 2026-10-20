require 'spec_helper'

RSpec.describe 'Packaged account interface' do
  it 'ships shared navigation, account helpers, forms and styles in the web gem' do
    specification = Dir.chdir(File.expand_path('..', __dir__)) { Gem::Specification.load('www.gemspec') }
    expect(specification.files).to include(
      'auth/navigation.rb', 'auth/helpers.rb', 'routes/accounts.rb', 'routes/pages.rb',
      'views/_account_navigation.erb', 'views/_profile_form.erb', 'views/account.erb',
      'public/css/account-navigation.css', 'public/css/account.css',
      'views/_preference_form.erb', 'public/js/account-preferences.js'
    )
  end
end
