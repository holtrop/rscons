if ENV["rscons_dist_specs"]
  require_relative "../test/rscons"
else
  require "simplecov"

  class MyFormatter
    def format(*args)
    end
  end
  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/.bundle/"
    if ENV["partial_specs"]
      command_name "RSpec-partial"
    else
      command_name "RSpec"
    end
    add_filter "test/rscons.rb"
    project_name "Rscons"
    merge_timeout 3600
    formatter(MyFormatter)
  end

  require "rscons"
end
