require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  t.pattern = '{core,cli,www}/spec/**/*_spec.rb'
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new(:lint)
rescue LoadError
  task :lint do
    warn 'rubocop not available; skipping lint'
  end
end

desc 'Run specs across every sub-gem'
task :test_all do
  %w[core cli www].each do |dir|
    sh "cd #{dir} && bundle exec rspec" if Dir.exist?(File.join(dir, 'spec'))
  end
end

task default: %i[spec lint]
