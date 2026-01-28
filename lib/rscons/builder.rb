require "fileutils"

module Rscons
  # Namespace module in which to store builders for convenient grouping
  module Builders; end

  # Class to hold an object that knows how to build a certain type of file.
  class Builder

    class << self
      # Return a String specifying an extra path component used to
      # differentiate build targets built by this builder from others.
      #
      # @return [String, nil]
      #   Extra path component used to differentiate build targets built by
      #   this builder from others.
      def extra_path
      end

      # Return the name of the builder.
      #
      # If not overridden this defaults to the last component of the class name.
      #
      # @return [String] The name of the builder.
      def name
        super.split(":").last
      end
    end

    # @return [String, Symbol]
    #   Target file name.
    attr_reader :target

    # @return [String, Symbol]
    #   Absolute target file name.
    attr_reader :abstarget

    # @return [Array<String, Symbol>]
    #   Source file names.
    attr_reader :sources

    # @return [Array<String, Symbol>]
    #   Absolute source file names.
    attr_reader :abssources

    # @return [Cache]
    #   Cache instance.
    attr_reader :cache

    # @return [Environment]
    #   The {Environment} performing the build operation.
    attr_reader :env

    # @return [Hash, VarSet]
    #   Construction variables used to perform the build operation.
    attr_accessor :vars

    # @return [Set<String>]
    #   Side effect file(s) produced when this builder runs.
    attr_reader :side_effects

    # @return [Integer]
    #   Build step.
    attr_accessor :build_step

    # Create an instance of the Builder to build a target.
    #
    # @param options [Hash]
    #   Options.
    # @option options [String, Symbol] :target
    #   Target file name.
    # @option options [Array<String>] :sources
    #   Source file name(s).
    # @option options [Cache] :cache
    #   The Cache object.
    # @option options [Environment] :env
    #   The Environment executing the builder.
    # @option options [Hash,VarSet] :vars
    #   Extra construction variables.
    def initialize(options)
      @target = options[:target]
      @abstarget = Util.absolute_path(@target)
      @sources = Array(options[:sources])
      @abssources = @sources.map do |source|
        Util.absolute_path(source)
      end
      @cache = options[:cache]
      @env = options[:env]
      @vars = options[:vars]
      @side_effects = Set.new
    end

    # Return the name of the builder.
    #
    # If not overridden this defaults to the last component of the class name.
    #
    # @return [String] The name of the builder.
    def name
      self.class.name
    end

    # Manually record a given build target as depending on the specified files.
    #
    # @param user_deps [Array<String>]
    #   Dependency files.
    #
    # @return [void]
    def depends(*user_deps)
      @env.depends(@target, *user_deps)
    end

    # Manually record the given side effect file(s) as being produced when the
    # named target is produced.
    #
    # @return [void]
    def produces(*side_effects)
      side_effects.each do |side_effect|
        side_effect_expanded = Util.absolute_path(@env.expand(side_effect))
        @env.register_side_effect(side_effect_expanded)
        @side_effects << side_effect_expanded
      end
    end

    # Run the builder to produce a build target.
    #
    # @param options [Hash]
    #   Run options.
    #
    # @return [Object]
    #   If the build operation fails, this method should return +false+.
    #   If the build operation succeeds, this method should return +true+.
    #   If the build operation is not yet complete and is waiting on other
    #   operations, this method should return the return value from the
    #   {#wait_for} method.
    def run(options)
      raise "This method must be overridden in a subclass"
    end

    # Print the builder run message, depending on the Environment's echo mode.
    #
    # @param short_description [String]
    #   Builder short description, printed if the echo mode is :short, or if
    #   there is no command.
    # @param command [Array<String>]
    #   Builder command, printed if the echo mode is :command.
    #
    # @return [void]
    def print_run_message(short_description, command)
      @env.print_builder_run_message(self, short_description, command)
    end

    # Create a {Command} object to execute the build command in a thread.
    #
    # @param short_description [String]
    #   Short description of build action to be printed when env.echo ==
    #   :short.
    # @param command [Array<String>]
    #   The command to execute.
    # @param options [Hash]
    #   Options.
    # @option options [String] :stdout
    #   File name to redirect standard output to.
    #
    # @return [Object]
    #   Return value for {#run} method.
    def register_command(short_description, command, options = {})
      command_options = {}
      if options[:stdout]
        command_options[:system_options] = {out: options[:stdout]}
      end
      print_run_message(short_description, @command)
      wait_for(Command.new(command, self, command_options))
    end

    # Check if the cache is up to date for the target and if not create a
    # {Command} object to execute the build command in a thread.
    #
    # @param short_description [String]
    #   Short description of build action to be printed when env.echo ==
    #   :short.
    # @param command [Array<String>]
    #   The command to execute.
    # @param options [Hash]
    #   Options.
    # @option options [Array<String>] :sources
    #   Sources to override @sources.
    # @option options [String] :stdout
    #   File name to redirect standard output to.
    #
    # @return [Object]
    #   Return value for {#run} method.
    def standard_command(short_description, command, options = {})
      @command = command
      sources = options[:sources] || @sources
      if @cache.up_to_date?(@target, @command, sources, @env)
        true
      else
        unless Rscons.phony_target?(@target)
          @cache.mkdir_p(File.dirname(@target))
          FileUtils.rm_f(@target)
        end
        register_command(short_description, @command, options)
      end
    end

    # Register build results from a {Command} with the cache.
    #
    # @param options [Hash]
    #   Builder finalize options.
    # @option options [String] :stdout
    #   File name to redirect standard output to.
    #
    # @return [true]
    #   Return value for {#run} method.
    def finalize_command(options = {})
      sources = options[:sources] || @sources
      @cache.register_build(@target, @command, sources, @env)
      true
    end

    # A builder can indicate to Rscons that it needs to wait for a separate
    # operation to complete by using this method. The return value from this
    # method should be returned from the builder's #run method.
    #
    # @param things [Builder, Command, Thread, Array<Builder, Command, Thread>]
    #   Builder(s) or Command(s) or Thread(s) that this builder needs to wait
    #   for.
    def wait_for(things)
      Array(things)
    end

  end
end
