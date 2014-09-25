require "bundler"
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  raise LoadError.new("Unable to setup Bundler; you might need to `bundle install`: #{e.message}")
end

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "yard"
require "rake/clean"

CLEAN.include %w[build_test_run .yardoc doc coverage]
CLOBBER.include %w[pkg]

RSpec::Core::RakeTask.new(:spec)

YARD::Rake::YardocTask.new do |yard|
  yard.files = ['lib/**/*.rb']
end

task :default => :spec
