require "set"

module Rscons

  # Functionality for an instance of the rscons application invocation.
  class Application

    # @return [Array<Hash>]
    #   Active variants.
    attr_reader :active_variants

    # @return [String]
    #   Top-level build directory.
    attr_accessor :build_dir

    # @return [Boolean]
    #   Whether to output ANSI color escape sequences.
    attr_accessor :do_ansi_color

    # @return [Integer]
    #   The number of threads to use when scheduling subprocesses.
    attr_accessor :n_threads

    # @return [Script]
    #   Build script.
    attr_reader :script

    # @return [Boolean]
    #   Whether to configure silently.
    attr_accessor :silent_configure

    # @return [Boolean]
    #   Whether to run verbosely.
    attr_accessor :verbose

    # Create Application instance.
    def _initialize
      @silent_configure = true
      @build_dir = ENV["RSCONS_BUILD_DIR"] || "build"
      ENV.delete("RSCONS_BUILD_DIR")
      @n_threads = Util.determine_n_threads
      @variant_groups = []
    end

    # Return if Rscons is in the task execution phase.
    #
    # @api private
    #
    # @return [Boolean]
    #   If Rscons is in the task execution phase.
    def task_execution_phase?
      @task_execution_phase
    end

    # Run the application.
    #
    # Execute user-specified tasks.
    #
    # @api private
    #
    # @param rsconscript [String]
    #   Build script file name.
    # @param tasks_and_params [Hash<String => Hash<String => String>>]
    #   List of task(s) to execute.
    # @param show_tasks [Boolean]
    #   Flag to show tasks and exit.
    # @param all_tasks [Boolean]
    #   Flag to show all tasks (not just those with a description).
    # @param enabled_variants [String]
    #   User-specified variants list.
    #
    # @return [Integer]
    #   Process exit code (0 on success).
    def run(rsconscript, tasks_and_params, show_tasks, all_tasks, enabled_variants)
      Cache.instance["failed_commands"] = []
      @tasks_and_params = tasks_and_params
      @enabled_variants = enabled_variants
      if enabled_variants == "" && !tasks_and_params.include?("configure")
        if cache_enabled_variants = Cache.instance["configuration_data"]["enabled_variants"]
          @enabled_variants = cache_enabled_variants
        end
      end
      @script = Script.new
      if should_load_script
        @script.load(rsconscript)
        enable_variants
      end
      if show_tasks
        show_script_tasks(all_tasks)
        return 0
      end
      apply_task_params(false)
      @task_execution_phase = true
      if tasks_and_params.empty?
        check_process_environments
        if Task.tasks["default"]
          Task["default"].check_execute
        end
      else
        tasks_and_params.each do |task_name, params|
          Task[task_name].check_execute
        end
      end
      0
    end

    # Apply user-specified variant enables and complain if they don't make
    # sense given the build script variant configuration.
    def enable_variants
      unless @_variants_enabled
        if @enabled_variants != ""
          exact = !(@enabled_variants =~ /^(\+|-)/)
          enabled_variants = @enabled_variants.split(",")
          specified_variants = {}
          enabled_variants.each do |enable_variant|
            enable_variant =~ /^(\+|-)?(.*)$/
            enable_disable, variant_name = $1, $2
            specified_variants[variant_name] = enable_disable != "-"
          end
          each_variant do |variant|
            if specified_variants.include?(variant[:name])
              variant[:enabled] = specified_variants[variant[:name]]
            elsif exact
              variant[:enabled] = false
            end
          end
        end
        @_variants_enabled = true
      end
      check_enabled_variants
    end

    # Show the last failures.
    #
    # @return [void]
    def show_failure
      failed_commands = Cache.instance["failed_commands"]
      failed_commands.each_with_index do |command, i|
        Ansi.write($stdout, :red, "Failed command (#{i + 1}/#{failed_commands.size}):", :reset, "\n")
        $stdout.puts Util.command_to_s(command)
      end
    end

    # Remove all generated files.
    #
    # @api private
    #
    # @return [void]
    def clean
      cache = Cache.instance
      # remove all built files
      cache.targets(false).each do |target|
        cache.remove_target(target)
        FileUtils.rm_f(target)
      end
      # remove all created directories if they are empty
      cache.directories(false).sort {|a, b| b.size <=> a.size}.each do |directory|
        cache.remove_directory(directory)
        next unless File.directory?(directory)
        if (Dir.entries(directory) - ['.', '..']).empty?
          Dir.rmdir(directory) rescue nil
        end
      end
      cache.write
    end

    # Remove the build directory and clear the cache.
    #
    # @api private
    #
    # @return [void]
    def distclean
      cache = Cache.instance
      clean
      cache.clear
      FileUtils.rm_rf(@build_dir)
    end

    # Check if the project needs to be configured.
    #
    # @api private
    #
    # @return [void]
    def check_configure
      apply_task_params(true)
      enable_variants
      unless Cache.instance["configuration_data"]["configured"]
        if @script.autoconf
          configure
        end
      end
    end

    # Check if environments need to be processed.
    #
    # @api private
    #
    # @return [void]
    def check_process_environments
      unless @_processed_environments
        Environment[].each do |env|
          env.process
        end
        @_processed_environments = true
      end
    end

    # Configure the project.
    #
    # @api private
    #
    # @return [void]
    def configure
      unless @_configured
        @_configured = true
        co = ConfigureOp.new(@script)
        begin
          @script.configure(co)
        rescue RsconsError => e
          co.close(false)
          raise e
        end
        Cache.instance["configuration_data"]["enabled_variants"] = @enabled_variants
        co.close(true)
      end
    end

    # Remove installed files.
    #
    # @api private
    #
    # @return [Integer]
    #   Exit code.
    #
    # @return [void]
    def uninstall
      cache = Cache.instance
      cache.targets(true).each do |target|
        cache.remove_target(target)
        next unless File.exist?(target)
        puts "Removing #{target}" if verbose
        FileUtils.rm_f(target)
      end
      # remove all created directories if they are empty
      cache.directories(true).sort {|a, b| b.size <=> a.size}.each do |directory|
        cache.remove_directory(directory)
        next unless File.directory?(directory)
        if (Dir.entries(directory) - ['.', '..']).empty?
          puts "Removing #{directory}" if verbose
          Dir.rmdir(directory) rescue nil
        end
      end
      cache.write
    end

    # Define a variant, or within a with_variants block, query if it is
    # active.
    #
    # @param name [String]
    #   Variant name.
    # @param options [Hash]
    #   Optional parameters.
    # @option options [String] :default
    #   Whether the variant is enabled by default (default: true).
    # @option options [String] :key
    #   Variant key, used to name an Environment's build directory. If nil,
    #   this variant will not contribute to the Environment's build directory
    #   name.
    def variant(name, options = {})
      if @active_variants
        !!@active_variants.find {|variant| variant[:name] == name}
      else
        if @variant_groups.empty?
          variant_group
        end
        options = options.dup
        options[:name] = name
        options[:enabled] = options.fetch(:default, true)
        options[:key] = options.fetch(:key, name)
        @variant_groups.last[:variants] << options
      end
    end

    # Check if a variant is enabled.
    #
    # This can be used, for example, in a configuration block to omit or
    # include configuration checks based on which variants have been
    # configured.
    #
    # @param variant_name [String]
    #   Variant name.
    #
    # @return [Boolean]
    #   Whether the requested variant is enabled.
    def variant_enabled?(variant_name)
      each_variant do |variant|
        if variant[:name] == variant_name
          return variant[:enabled]
        end
      end
      false
    end

    # Create a variant group.
    #
    # @overload variant_group(name, options = {})
    #   @param name [String]
    #     Variant group name (optional).
    #   @param options [Hash]
    #     Optional variant group parameters.
    # @overload variant_group(options = {})
    #   @param options [Hash]
    #     Optional variant group parameters.
    def variant_group(*args, &block)
      if args.first.is_a?(String)
        name = args.slice!(0)
      end
      options = args.first || {}
      @variant_groups << options.merge(name: name, variants: [])
      if block
        block[]
      end
    end

    # Iterate through enabled variants.
    #
    # The given block is called for each combination of enabled variants
    # across the defined variant groups.
    def with_variants(&block)
      if @active_variants
        raise "with_variants cannot be called within another with_variants block"
      end
      if @variant_groups.empty?
        raise "with_variants cannot be called with no variants defined"
      end
      iter_vgs = lambda do |iter_variants|
        if iter_variants.size == @variant_groups.size
          @active_variants = iter_variants.compact
          block[]
          @active_variants = nil
        else
          @variant_groups[iter_variants.size][:variants].each do |variant|
            if variant[:enabled]
              iter_vgs[iter_variants + [variant]]
            end
          end
        end
      end
      iter_vgs[[]]
    end

    private

    def check_enabled_variants
      @variant_groups.each do |variant_group|
        enabled_count = variant_group[:variants].count do |variant|
          variant[:enabled]
        end
        if enabled_count == 0
          message = "No variants enabled for variant group"
          if variant_group[:name]
            message += " #{variant_group[:name].inspect}"
          end
          raise RsconsError.new(message)
        end
      end
    end

    def each_variant
      @variant_groups.each do |variant_group|
        variant_group[:variants].each do |variant|
          yield variant
        end
      end
    end

    def show_script_tasks(all_tasks)
      puts "Tasks:"
      Task[].sort.each do |task_name, task|
        if task.description || all_tasks
          puts %[  #{sprintf("%-27s", task_name)} #{task.description}]
          task.params.each do |param_name, param|
            arg_text = "--#{param_name}"
            if param.takes_arg
              arg_text += "=#{param_name.upcase}"
            end
            puts %[    #{sprintf("%-25s", "#{arg_text}")} #{param.description}]
          end
        end
      end

      unless @variant_groups.empty?
        @variant_groups.each do |variant_group|
          puts "\nVariant group#{variant_group[:name] ? " '#{variant_group[:name]}'" : ""}:"
          variant_group[:variants].each do |variant|
            puts "  #{variant[:name]}#{variant[:enabled] ? " (enabled)" : ""}"
          end
        end
      end
    end

    def apply_task_params(only_configure)
      @tasks_and_params.each do |task_name, task_params|
        unless only_configure && task_name != "configure"
          task_params.each do |param_name, param_value|
            if param = Task[task_name].params[param_name]
              Task[task_name].set_param_value(param_name, param_value)
            else
              raise RsconsError.new("Unknown parameter #{param_name.inspect} for task #{task_name}")
            end
          end
        end
      end
    end

    def should_load_script
      return true if @tasks_and_params.empty?
      return true if Cache.instance["configuration_data"]["configured"]
      return false if (@tasks_and_params.keys - %w[distclean clean uninstall]).empty?
      true
    end

  end

end
