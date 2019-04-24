require_relative "rscons/ansi"
require_relative "rscons/application"
require_relative "rscons/basic_environment"
require_relative "rscons/builder"
require_relative "rscons/builder_builder"
require_relative "rscons/builder_set"
require_relative "rscons/cache"
require_relative "rscons/command"
require_relative "rscons/configure_op"
require_relative "rscons/default_construction_variables"
require_relative "rscons/environment"
require_relative "rscons/script"
require_relative "rscons/util"
require_relative "rscons/varset"
require_relative "rscons/version"

# Namespace module for rscons classes
module Rscons

  # Names of the default builders which will be added to all newly created
  # {Environment} objects.
  DEFAULT_BUILDERS = [
    :CFile,
    :Command,
    :Copy,
    :Directory,
    :Disassemble,
    :Install,
    :InstallDirectory,
    :Library,
    :Object,
    :Preprocess,
    :Program,
    :SharedLibrary,
    :SharedObject,
  ]

  # Class to represent a fatal error while building a target.
  class BuildError < RuntimeError; end

  class << self

    # Access the Application singleton.
    #
    # @return [Application]
    #   The Application singleton.
    def application
      @application ||= Application.new
    end

    # Access any variables set on the rscons command-line.
    #
    # @return [VarSet]
    def vars(*args)
      application.vars(*args)
    end

    # Return whether the given target is a phony target.
    #
    # @param target [Symbol, String] Target name.
    #
    # @return [Boolean] Whether the given target is a phony target.
    def phony_target?(target)
      target.is_a?(Symbol)
    end

    # Return a new path by changing the suffix in path to suffix.
    #
    # @param path [String] The path to alter.
    # @param suffix [String] The new filename suffix, e.g. ".exe".
    #
    # @return [String] New path.
    def set_suffix(path, suffix)
      path.sub(/\.[^.]*$/, "") + suffix
    end

    # Return the system shell and arguments for executing a shell command.
    #
    # @return [Array<String>] The shell and flag.
    def get_system_shell
      @shell ||=
        begin
          test_shell = lambda do |*args|
            begin
              "success" == IO.popen([*args, "echo success"]) do |io|
                io.read.strip
              end
            rescue
              false
            end
          end
          if ENV["SHELL"] and ENV["SHELL"] != "" and test_shell[ENV["SHELL"], "-c"]
            [ENV["SHELL"], "-c"]
          elsif Object.const_get("RUBY_PLATFORM") =~ /mingw/
            if test_shell["sh", "-c"]
              # Using Rscons from MSYS should use MSYS's shell.
              ["sh", "-c"]
            else
              ["cmd", "/c"]
            end
          else
            ["sh", "-c"]
          end
        end
    end

    # Return an Array containing a command used to execute commands.
    #
    # This will normally be an empty Array, but on Windows if Rscons detects
    # that it is running in MSYS then ["env"] will be returned.
    #
    # @return [Array<String>] Command used to execute commands.
    def command_executer
      @command_executer ||=
        if Object.const_get("RUBY_PLATFORM") =~ /mingw/
          if ENV.keys.find {|key| key =~ /MSYS/}
            begin
              if IO.popen(["env", "echo", "success"]) {|io| io.read.strip} == "success"
                ["env"]
              end
            rescue
            end
          end
        end || []
    end

    # Set the command executer array.
    #
    # @param val [Array<String>] Command used to execute commands.
    #
    # @return [Array<String>] Command used to execute commands.
    def command_executer=(val)
      @command_executer = val
    end

  end

end

# builder mixins
require_relative "rscons/builders/mixins/depfile"
require_relative "rscons/builders/mixins/object"
require_relative "rscons/builders/mixins/object_deps"
require_relative "rscons/builders/mixins/program"

# default builders
require_relative "rscons/builders/cfile"
require_relative "rscons/builders/command"
require_relative "rscons/builders/copy"
require_relative "rscons/builders/directory"
require_relative "rscons/builders/disassemble"
require_relative "rscons/builders/library"
require_relative "rscons/builders/object"
require_relative "rscons/builders/preprocess"
require_relative "rscons/builders/program"
require_relative "rscons/builders/shared_library"
require_relative "rscons/builders/shared_object"
require_relative "rscons/builders/simple_builder"

# language support
require_relative "rscons/builders/lang/asm"
require_relative "rscons/builders/lang/c"
require_relative "rscons/builders/lang/cxx"
require_relative "rscons/builders/lang/d"

# Unbuffer $stdout
$stdout.sync = true
