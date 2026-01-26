require "bundler"
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  raise LoadError.new("Unable to setup Bundler; you might need to `bundle install`: #{e.message}")
end

require "rspec/core/rake_task"
require "rake/clean"
require "fileutils"

CLEAN.include %w[build_test_run .yardoc yard coverage test_run]
CLOBBER.include %w[dist gen large_project pkg]

task :build_dist do
  sh "ruby rb/build_dist.rb"
end

RSpec::Core::RakeTask.new(:spec, :example_string) do |task, args|
  ENV["specs"] = "1"
  if args.example_string
    task.rspec_opts = %W[-e "#{args.example_string}" -f documentation]
  end
end
task :spec => :build_dist
task :spec do
  ENV.delete("specs")
end
task :spec => :build_tests

task :build_tests do |task, args|
  ENV["specs"] = "1"
  sh "ruby -Ilib build_tests/build_tests.rb"
  ENV.delete("specs")
end

# dspec task is useful to test the distributable release script, but is not
# useful for coverage information.
desc "Dist Specs"
task :dspec, [:example_string] => :build_dist do |task, args|
  FileUtils.rm_rf("test_run")
  FileUtils.mkdir_p("test_run")
  FileUtils.cp("dist/rscons", "test_run/rscons.rb")
  ENV["rscons_dist_specs"] = "1"
  Rake::Task["spec"].execute(args)
  ENV.delete("rscons_dist_specs")
  FileUtils.rm_f(Dir.glob(".rscons-*"))
end

task :gen_large_project, [:size] => :build_dist do |task, args|
  size = (args.size || 10000).to_i
  FileUtils.rm_rf("large_project")
  FileUtils.mkdir_p("large_project/src")
  size.times do |i|
    File.open("large_project/src/fn#{i}.c", "w") do |fh|
      fh.puts(<<-EOF)
        int fn#{i}(void)
        {
          return #{i};
        }
      EOF
    end
    File.open("large_project/src/fn#{i}.h", "w") do |fh|
      fh.puts %[int fn#{i}(void);]
    end
  end
  File.open("large_project/src/main.c", "w") do |fh|
    size.times do |i|
      fh.puts %[#include "fn#{i}.h"]
    end
    fh.puts <<-EOF
      int main(int argc, char * argv[])
      {
        int result = 0;
    EOF
    size.times do |i|
      fh.puts %[result += fn#{i}();]
    end
    fh.puts <<-EOF
        return result;
      }
    EOF
  end
  File.open("large_project/Rsconscript", "w") do |fh|
    fh.puts <<EOF
default do
  Environment.new do |env|
    env.Program("project", glob("src/*.c"))
  end
end
EOF
  end
  FileUtils.cp("dist/rscons", "large_project")
end

unless RbConfig::CONFIG["host"]["msys"]
  require "yard"
  YARD::Rake::YardocTask.new do |yard|
    yard.files = ['lib/**/*.rb']
    yard.options = ["-ogen/yard"]
  end

  desc "Build user guide"
  task :user_guide do
    system("ruby", "-Ilib", "rb/gen_user_guide.rb")
  end
end

task :default => :spec

task :all => [
  :build_dist,
  :spec,
  :dspec,
  :yard,
  :user_guide,
]
