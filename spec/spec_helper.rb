if ENV["dist_specs"]
  require_relative "../test/rscons"
else
  require "simplecov"

  SimpleCov.start do
    add_filter "/spec/"
    add_filter "/.bundle/"
    if ENV["partial_specs"]
      command_name "RSpec-partial"
    else
      command_name "RSpec"
    end
    if ENV["dist_specs"]
      add_filter "/bin/"
      add_filter "/lib/"
    else
      add_filter "test/rscons.rb"
    end
    project_name "Rscons"
    merge_timeout 3600
  end

  require "rscons"
end
