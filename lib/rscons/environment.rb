require "fileutils"
require "set"
require "shellwords"

module Rscons
  # The Environment class is the main programmatic interface to Rscons. It
  # contains a collection of construction variables, options, builders, and
  # rules for building targets.
  class Environment < BasicEnvironment

    class << self

      # @return [Environment]
      #   The Environment that is currently executing a construction block.
      attr_accessor :running_environment

      # Initialize class instance variables.
      def class_init
        @environments_by_name = {}
        @environments = []
      end

      # Get an ID for a new Environment. This is a monotonically increasing
      # integer.
      #
      # @return [Integer]
      #   Environment ID.
      def get_id
        @id ||= 0
        @id += 1
        @id
      end

      # Register an Environment.
      def register(env)
        @environments << env
        if env.name
          @environments_by_name[env.name] = env
        end
      end

      # Get an Environment by name.
      #
      # @param name [String]
      #   Environment name.
      def [](name = nil)
        if name
          @environments_by_name[name]
        else
          @environments
        end
      end

    end

    # @return [Hash] Set of !{"builder_name" => builder_object} pairs.
    attr_reader :builders

    # @return [Symbol] :command, :short, or :off
    attr_accessor :echo

    # @return [String] The build root.
    attr_reader :build_root

    # @return [Integer]
    #   The number of threads to use for this Environment. Defaults to the
    #   global Rscons.application.n_threads value.
    attr_accessor :n_threads

    # @return [String]
    #   Environment name.
    attr_reader :name

    # Create an Environment object.
    def initialize(*args, &block)
      @id = self.class.get_id
      variant_keys = (Rscons.application.active_variants || []).map do |variant|
        variant[:key]
      end.compact
      if args.first.is_a?(String)
        base_name = args.slice!(0)
        @name = [base_name, *variant_keys].join("-")
        @build_root = "#{Rscons.application.build_dir}/#{@name}"
      else
        if variant_keys.size > 0
          raise RsconsError.new("Error: an Environment with active variants must be given a name")
        end
        @build_root = Rscons.application.build_dir
      end
      options = args.first || {}
      unless Cache.instance["configuration_data"]["configured"]
        raise "Project must be configured before creating an Environment"
      end
      super(options)
      # Hash of Thread object => {Command} or {Builder}.
      @threads = {}
      @registered_build_dependencies = {}
      # Set of side-effect files that have not yet been built.
      @side_effects = Set.new
      @builder_sets = []
      @build_targets = {}
      @user_deps = {}
      # Hash of builder name (String) => builder class (Class).
      @builders = {}
      @build_hooks = {pre: [], post: []}
      unless options[:exclude_builders]
        DEFAULT_BUILDERS.each do |builder_class_name|
          builder_class = Builders.const_get(builder_class_name)
          builder_class or raise "Could not find builder class #{builder_class_name}"
          add_builder(builder_class)
        end
      end
      @echo =
        if options[:echo]
          options[:echo]
        elsif Rscons.application.verbose
          :command
        else
          :short
        end
      @n_threads = Rscons.application.n_threads
      @build_steps = 0
      self.class.register(self)
      if block
        Environment.running_environment = self
        block[self]
        Environment.running_environment = nil
      end
    end

    # Make a copy of the Environment object.
    #
    # By default, a cloned environment will contain a copy of all environment
    # options, construction variables, and builders, but not a copy of the
    # targets, build hooks, build directories, or the build root.
    #
    # Exactly which items are cloned are controllable via the optional :clone
    # parameter, which can be :none, :all, or a set or array of any of the
    # following:
    # - :variables to clone construction variables (on by default)
    # - :builders to clone the builders (on by default)
    # - :build_hooks to clone the build hooks (on by default)
    #
    # If a block is given, the Environment object is yielded to the block and
    # when the block returns, the {#process} method is automatically called.
    #
    # Any options that #initialize receives can also be specified here.
    #
    # @return [Environment] The newly created {Environment} object.
    def clone(*args, &block)
      if args.first.is_a?(String)
        name = args.slice!(0)
      end
      options = args.first || {}
      options = options.dup
      clone = options[:clone] || :all
      clone = Set[:variables, :builders, :build_hooks] if clone == :all
      clone = Set[] if clone == :none
      clone = Set.new(clone) if clone.is_a?(Array)
      clone.delete(:builders) if options[:exclude_builders]
      options[:echo] ||= @echo
      new_args = name ? [name] : []
      new_args << options.merge(exclude_builders: true)
      env = self.class.new(*new_args)
      if clone.include?(:builders)
        @builders.each do |builder_name, builder|
          env.add_builder(builder)
        end
      end
      env.append(@varset) if clone.include?(:variables)
      if clone.include?(:build_hooks)
        @build_hooks[:pre].each do |build_hook_block|
          env.add_build_hook(&build_hook_block)
        end
        @build_hooks[:post].each do |build_hook_block|
          env.add_post_build_hook(&build_hook_block)
        end
      end
      env.instance_variable_set(:@n_threads, @n_threads)
      if block
        Environment.running_environment = self
        block[env]
        Environment.running_environment = nil
      end
      env
    end

    # Add a {Builder} to the Environment.
    #
    # @overload add_builder(builder_class)
    #
    #   Add the given builder to the Environment.
    #
    #   @param builder_class [Class] A builder class to register.
    #
    # @overload add_builder(name,&action)
    #
    #   Create a new {Builders::SimpleBuilder} instance and add it to the
    #   environment.
    #
    #   @param name [String,Symbol]
    #     The name of the builder to add.
    #
    #   @param action [Block]
    #     A block that will be called when the builder is executed to generate
    #     a target file. The provided block should have the same prototype as
    #     {Rscons::Builder#run}.
    #
    # @return [void]
    def add_builder(builder_class, &action)
      if builder_class.is_a?(String) or builder_class.is_a?(Symbol)
        name = builder_class.to_s
        builder_class = BuilderBuilder.new(Rscons::Builders::SimpleBuilder, name, &action)
      else
        name = builder_class.name
      end
      @builders[name] = builder_class
    end

    # Add a build hook to the Environment.
    #
    # Build hooks are Ruby blocks which are invoked immediately before a
    # build operation takes place. Build hooks have an opportunity to modify
    # the construction variables in use for the build operation based on the
    # builder in use, target file name, or sources. Build hooks can also
    # register new build targets.
    #
    # @yield [build_op]
    #   Invoke the given block with the current build operation.
    # @yieldparam build_op [Hash]
    #   Hash with keys:
    #   - :builder - The builder object in use.
    #   - :target - Target file name.
    #   - :sources - List of source file(s).
    #   - :vars - Set of construction variable values in use.
    #   - :env - The Environment invoking the builder.
    #
    # @return [void]
    def add_build_hook(&block)
      @build_hooks[:pre] << block
    end

    # Add a post build hook to the Environment.
    #
    # Post-build hooks are Ruby blocks which are invoked immediately after a
    # build operation takes place. Post-build hooks are only invoked if the
    # build operation succeeded. Post-build hooks can register new build
    # targets.
    #
    # @yield [build_op]
    #   Invoke the given block with the current build operation.
    # @yieldparam build_op [Hash]
    #   Hash with keys:
    #   - :builder - The builder object in use.
    #   - :target - Target file name.
    #   - :sources - List of source file(s).
    #   - :vars - Set of construction variable values in use.
    #   - :env - The Environment invoking the builder.
    #
    # @return [void]
    def add_post_build_hook(&block)
      @build_hooks[:post] << block
    end

    # Return the file name to be built from +source_fname+ with suffix
    # +suffix+.
    #
    # This method takes into account the Environment's build directories.
    #
    # @param source_fname [String]
    #   Source file name.
    # @param suffix [String]
    #   Suffix, including "." if desired.
    # @param builder_class [Class]
    #   The builder in use.
    #
    # @return [String]
    #   The file name to be built from +source_fname+ with suffix +suffix+.
    def get_build_fname(source_fname, suffix, builder_class)
      if extra_path = builder_class.extra_path
        extra_path = "/#{extra_path}"
      end
      source_fname = source_fname.gsub("\\", "/")
      if extra_path.nil? && source_fname.start_with?("#{@build_root}/")
        # If the source file is in the environment's build directory and no
        # builder "extra path" is present, then just place the output file
        # next to the source file.
        "#{source_fname}#{suffix}"
      else
        "#{@build_root}/o#{extra_path}/#{Util.make_relative_path("#{source_fname}#{suffix}")}"
      end
    end

    # Get a path under the build root for precompile outputs.
    #
    # @param end_path [String]
    #   Path to append to precompile build root.
    #
    # @return [String]
    #   Precompile directory name.
    def get_pc_build_dir(end_path)
      "#{@build_root}/pc/#{Util.make_relative_path(end_path)}"
    end

    # Build all build targets specified in the Environment.
    #
    # When a block is passed to Environment.new, this method is automatically
    # called after the block returns.
    #
    # @return [void]
    def process
      Cache.instance.clear_checksum_cache!
      @process_failures = []
      @process_blocking_wait = false
      @process_commands_waiting_to_run = []
      @process_builder_waits = {}
      @process_builders_to_run = []
      @build_step = 0
      @build_steps = @builder_sets.reduce(0) do |result, builder_set|
        result + builder_set.build_steps_remaining
      end
      begin
        while @builder_sets.size > 0 or @threads.size > 0 or @process_commands_waiting_to_run.size > 0
          process_step
          if @builder_sets.size > 0 and @builder_sets.first.empty? and @threads.empty? and @process_commands_waiting_to_run.empty? and @process_builders_to_run.empty?
            # Remove empty BuilderSet when all other operations have completed.
            @builder_sets.slice!(0)
          end
          unless @process_failures.empty?
            # On a build failure, do not start any more builders or commands,
            # but let the threads that have already been started complete.
            @builder_sets.clear
            @process_commands_waiting_to_run.clear
          end
        end
      ensure
        Cache.instance.write
      end
      unless @process_failures.empty?
        msg = @process_failures.join("\n")
        if Cache.instance["failed_commands"].size > 0
          msg += "\nUse `#{Util.command_to_execute_me} -F` to view the failed command log from the previous build operation"
        end
        raise RsconsError.new(msg)
      end
    end

    # Clear all targets registered for the Environment.
    #
    # @return [void]
    def clear_targets
      @builder_sets.clear
    end

    # Define a build target.
    #
    # @param method [Symbol] Method name.
    # @param args [Array] Method arguments.
    #
    # @return [Builder]
    #   The {Builder} object registered, if the method called is the name of a
    #   registered {Builder}.
    def method_missing(method, *args)
      if @builders.has_key?(method.to_s)
        target, sources, vars, *rest = args
        vars ||= {}
        unless vars.is_a?(Hash) or vars.is_a?(VarSet)
          raise "Unexpected construction variable set: #{vars.inspect}"
        end
        target = expand(target)
        sources = Array(sources).map do |source|
          source = source.target if source.is_a?(Builder)
          expand(source)
        end.flatten
        builder = @builders[method.to_s].new(
          target: target,
          sources: sources,
          cache: Cache.instance,
          env: self,
          vars: vars)
        if @builder_sets.empty?
          @builder_sets << build_builder_set
        end
        @builder_sets.last << builder
        @build_steps += 1 unless builder.is_a?(Rscons::Builders::Barrier)
        @build_targets[builder.abstarget] = builder
        builder
      else
        super
      end
    end

    # Manually record a given target as depending on the specified files.
    #
    # @param target [String, Builder] Target file.
    # @param user_deps [Array<String, Builder>] Dependency files.
    #
    # @return [void]
    def depends(target, *user_deps)
      if target.is_a?(Builder)
        target = target.target
      end
      user_deps = user_deps.map do |ud|
        if ud.is_a?(Builder)
          ud = ud.target
        end
        expand(ud)
      end
      target = Util.absolute_path(expand(target))
      @user_deps[target] ||= []
      user_deps.map! {|ud| Util.absolute_path(ud)}
      user_deps.each do |ud|
        unless Rscons.phony_target?(ud) || @user_deps[target].include?(ud)
          @user_deps[target] << ud
        end
      end
      build_after(target, user_deps)
    end

    # Manually record the given target(s) as needing to be built after the
    # given prerequisite(s).
    #
    # For example, consider a builder registered to generate gen.c which also
    # generates gen.h as a side-effect. If program.c includes gen.h, then it
    # should not be compiled before gen.h has been generated. When using
    # multiple threads to build, Rscons may attempt to compile program.c before
    # gen.h has been generated because it does not know that gen.h will be
    # generated along with gen.c. One way to prevent that situation would be
    # to first process the Environment with just the code-generation builders
    # in place and then register the compilation builders. Another way is to
    # use this method to record that a certain target should not be built until
    # another has completed. For example, for the situation previously
    # described:
    #   env.build_after("program.o", "gen.c")
    #
    # @param targets [String, Array<String>]
    #   Target files to wait to build until the prerequisites are finished
    #   building.
    # @param prerequisites [String, Builder, Array<String, Builder>]
    #   Files that must be built before building the specified targets.
    #
    # @return [void]
    def build_after(targets, prerequisites)
      targets = Array(targets)
      prerequisites = Array(prerequisites)
      targets.each do |target|
        target = Util.absolute_path(expand(target))
        @registered_build_dependencies[target] ||= Set.new
        prerequisites.each do |prerequisite|
          if prerequisite.is_a?(Builder)
            prerequisite = prerequisite.target
          end
          prerequisite = Util.absolute_path(expand(prerequisite))
          @registered_build_dependencies[target] << prerequisite
        end
      end
    end

    # Manually record the given side effect file(s) as being produced when the
    # named target is produced.
    #
    # @param target [String]
    #   Target of a build operation.
    # @param side_effects [Array<String>]
    #   File(s) produced when the target file is produced.
    #
    # @return [void]
    def produces(target, *side_effects)
      abstarget = Util.absolute_path(expand(target))
      @builder_sets.reverse.each do |builder_set|
        if builders = builder_set[abstarget]
          builders.last.produces(*side_effects)
          return
        end
      end
      raise "Could not find a registered build target #{target.inspect}"
    end

    # Register a side effect file.
    #
    # This is an internally used method.
    #
    # @api private
    #
    # @param side_effect [String]
    #   Side effect fiel name.
    def register_side_effect(side_effect)
      @side_effects << Util.absolute_path(side_effect)
    end

    # Return the list of user dependencies for a given target.
    #
    # @param target [String] Target file name.
    #
    # @return [Array<String>,nil]
    #   List of user-specified dependencies for the target, or nil if none were
    #   specified.
    def get_user_deps(target)
      target = Util.absolute_path(target)
      @user_deps[target]
    end

    # Register a builder to build a source file into an output with the given
    # suffix.
    #
    # This method is used internally by Rscons builders. It can be called
    # from the builder's #initialize method.
    #
    # @param target [String]
    #   The target that depends on these builds.
    # @param source [String]
    #   Source file to build.
    # @param suffix [String]
    #   Suffix to try to convert source files into.
    # @param vars [Hash]
    #   Extra variables to pass to the builders.
    # @param builder_class [Class]
    #   The builder class to use.
    #
    # @return [String]
    #   Output file name.
    def register_dependency_build(target, source, suffix, vars, builder_class)
      target = Util.absolute_path(target)
      output_fname = get_build_fname(source, suffix, builder_class)
      @_registered_dependency_targets ||= Set.new
      unless @_registered_dependency_targets.include?(output_fname)
        self.__send__(builder_class.name, output_fname, source, vars)
        @_registered_dependency_targets << output_fname
      end
      @registered_build_dependencies[target] ||= Set.new
      @registered_build_dependencies[target] << Util.absolute_path(output_fname)
      output_fname
    end

    # Expand paths.
    #
    # Paths beginning with "^/" are expanded by replacing "^" with the
    # Environment's build root (e.g. "build/envname").
    # Paths beginning with "^^/" are expanded by replacing "^^" with the
    # top-level build directory (e.g. "build").
    #
    # @param path [String, Array<String>]
    #   The path(s) to expand.
    #
    # @return [String, Array<String>]
    #   The expanded path(s).
    def expand_path(path)
      if Rscons.phony_target?(path)
        path
      elsif path.is_a?(Array)
        path.map do |path|
          expand_path(path)
        end
      else
        path.sub(%r{^\^\^(?=[\\/])}, Rscons.application.build_dir).sub(%r{^\^(?=[\\/])}, @build_root).gsub("\\", "/")
      end
    end

    # Expand construction variable references and paths.
    #
    # @param expr [String]
    #   Expression to expand. Can contain construction variable references and
    #   a path.
    #
    # @return [String, Array<String>]
    #   Expanded value.
    def expand(expr)
      expand_path(expand_varref(expr))
    end

    # Print the builder run message, depending on the Environment's echo mode.
    #
    # @param builder [Builder]
    #   The {Builder} that is executing.
    # @param short_description [String]
    #   Builder short description, printed if the echo mode is :short, or if
    #   there is no command.
    # @param command [Array<String>, nil]
    #   Builder command, printed if the echo mode is :command.
    #
    # @return [void]
    def print_builder_run_message(builder, short_description, command)
      case @echo
      when :command
        if command.is_a?(Array)
          message = Util.command_to_s(command)
        elsif command.is_a?(String)
          message = command
        elsif short_description.is_a?(String)
          message = short_description
        end
      when :short
        message = short_description if short_description
      end
      if message
        total_build_steps = @build_steps.to_s
        this_build_step = sprintf("%#{total_build_steps.size}d", builder.build_step)
        progress = "[#{this_build_step}/#{total_build_steps}]"
        Ansi.write($stdout, *Util.colorize_markup("#{progress} #{message}"), "\n")
      end
    end

    # Get the Builder for a target.
    #
    # @return [Builder, nil]
    #   The {Builder} for target, or +nil+ if none found.
    def builder_for(target)
      target = Util.absolute_path(target)
      @build_targets[target]
    end

    # Mark a "barrier" point.
    #
    # Rscons will wait for all build targets registered before the barrier to
    # be built before beginning to build any build targets registered after
    # the barrier. In other words, Rscons will not parallelize build operations
    # across a barrier.
    def barrier
      @builder_sets << build_builder_set
    end

    # Set up builders and barrier for a precompile phase if needed.
    #
    # @param sources [Array<String>]
    #   Sources for the build operation.
    #
    # @return [Symbol, nil]
    #   Barrier target name if a precompile phase is needed, otherwise nil.
    def setup_precompile(sources)
      return unless sources.find {|s| s.end_with?(".d")}
      d_import_paths = self.expand_varref("${D_IMPORT_PATH}")
      precompile_paths = []
      import_paths_to_precompile_paths = {}
      d_import_paths.each do |import_path|
        precompile_path = get_pc_build_dir(import_path)
        precompile_paths << precompile_path
        Util.clean_d_precompile_path(precompile_path, import_path)
        import_paths_to_precompile_paths[import_path] = precompile_path
      end
      barrier_target = Rscons.gen_phony_target
      self.Barrier(barrier_target)
      sources.each do |source|
        next unless source.end_with?(".d")
        next unless module_name = Util.get_module_name(source)
        next unless import_path = Util.find_import_path_for_d_source(d_import_paths, source, module_name)
        precompile_path = import_paths_to_precompile_paths[import_path]
        pctarget = "#{precompile_path}/#{module_name.gsub(".", "/")}.di"
        @_precompile_targets ||= Set.new
        unless @_precompile_targets.include?(pctarget)
          self.Precompile(pctarget, source)
          @_precompile_targets << pctarget
        end
        self.depends(barrier_target, pctarget)
      end
      self["D_IMPORT_PATH"] = precompile_paths + self["D_IMPORT_PATH"]
      barrier_target
    end

    private

    # Build a BuilderSet.
    #
    # @return [BuilderSet]
    #   New {BuilderSet} object.
    def build_builder_set
      BuilderSet.new(@registered_build_dependencies, @side_effects)
    end

    # Get the next build step number.
    #
    # @api private
    #
    # @return [Integer]
    #   Next build step number.
    def get_next_build_step
      @build_step += 1
    end

    # Run a builder and process its return value.
    #
    # @param builder [Builder]
    #   The builder.
    #
    # @return [void]
    def run_builder(builder)
      unless builder.is_a?(Rscons::Builders::Barrier)
        builder.build_step ||= get_next_build_step
      end
      case result = builder.run({})
      when Array
        result.each do |waititem|
          @process_builder_waits[builder] ||= Set.new
          @process_builder_waits[builder] << waititem
          case waititem
          when Thread
            @threads[waititem] = builder
          when Command
            @process_commands_waiting_to_run << waititem
          when Builder
            # No action needed.
          else
            raise "Unrecognized #{builder.name} builder return item: #{waititem.inspect}"
          end
        end
      when false
        @process_failures << "Failed to build #{builder.target}."
      when true
        # Register side-effect files as build targets so that a Cache
        # clean operation will remove them.
        builder.side_effects.each do |side_effect|
          Cache.instance.register_build(side_effect, nil, [], self, side_effect: true)
          @side_effects.delete(side_effect)
        end
        unless builder.is_a?(Rscons::Builders::Barrier)
          @build_hooks[:post].each do |build_hook_block|
            build_hook_block.call(builder)
          end
        end
        process_remove_wait(builder)
      else
        raise "Unrecognized #{builder.name} builder return value: #{result.inspect}"
      end
    end

    # Remove an item that a builder may have been waiting on.
    #
    # @param waititem [Object]
    #   Item that a builder may be waiting on.
    #
    # @return [void]
    def process_remove_wait(waititem)
      @process_builder_waits.to_a.each do |builder, waits|
        if waits.include?(waititem)
          waits.delete(waititem)
        end
        if waits.empty?
          @process_builder_waits.delete(builder)
          @process_builders_to_run << builder
        end
      end
    end

    # Broken out from {#process} to perform a single operation.
    #
    # @return [void]
    def process_step
      # Check if a thread has completed since last time.
      thread = find_finished_thread(true)

      # Check if we need to do a blocking wait for a thread to complete.
      if thread.nil? and (@threads.size >= n_threads or @process_blocking_wait)
        thread = find_finished_thread(false)
        @process_blocking_wait = false
      end

      if thread
        # We found a completed thread.
        process_remove_wait(thread)
        unblocked_builder = builder_for_thread(thread)
        completed_command = @threads[thread]
        @threads.delete(thread)
        if completed_command.is_a?(Command)
          process_remove_wait(completed_command)
          completed_command.status = thread.value
          unless completed_command.status
            Cache.instance["failed_commands"] << completed_command.command
            @process_failures << "Failed to build #{unblocked_builder.target}."
            return
          end
        end
      end

      if @threads.size < n_threads and @process_commands_waiting_to_run.size > 0
        # There is a command waiting to run and a thread free to run it.
        command = @process_commands_waiting_to_run.slice!(0)
        @threads[command.run] = command
        return
      end

      unless @process_builders_to_run.empty?
        # There is a builder waiting to run that was unblocked by its wait
        # items completing.
        return run_builder(@process_builders_to_run.slice!(0))
      end

      # If no builder was found to run yet and there are threads available, try
      # to get a runnable builder from the builder set.
      targets_still_building = @threads.reduce([]) do |result, (thread, obj)|
        result << builder_for_thread(thread).abstarget
      end
      if @builder_sets.size > 0
        if builder = @builder_sets[0].get_next_builder_to_run(targets_still_building)
          builder.vars = @varset.merge(builder.vars)
          unless builder.is_a?(Rscons::Builders::Barrier)
            @build_hooks[:pre].each do |build_hook_block|
              build_hook_block.call(builder)
            end
          end
          return run_builder(builder)
        end
      end

      if @threads.size > 0
        # A runnable builder was not found but there is a thread running,
        # so next time do a blocking wait for a thread to complete.
        @process_blocking_wait = true
      end
    end

    # Find a finished thread.
    #
    # @param nonblock [Boolean]
    #   Whether to be non-blocking. If true, nil will be returned if no thread
    #   is finished. If false, the method will wait until one of the threads
    #   is finished.
    #
    # @return [Thread, nil]
    #   The finished thread, if any.
    def find_finished_thread(nonblock)
      if nonblock
        @threads.keys.find do |thread|
          !thread.alive?
        end
      else
        Util.wait_for_thread(*@threads.keys)
      end
    end

    # Get the {Builder} waiting on the given Thread.
    #
    # @param thread [Thread]
    #   The thread.
    #
    # @return [Builder]
    #   The {Builder} waiting on the given thread.
    def builder_for_thread(thread)
      if @threads[thread].is_a?(Command)
        @threads[thread].builder
      else
        @threads[thread]
      end
    end

  end

  Environment.class_init
end
