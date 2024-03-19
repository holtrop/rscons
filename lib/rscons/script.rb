module Rscons

  # The Script class encapsulates the state of a build script.
  class Script

    # Global DSL methods.
    class GlobalDsl
      # Create a GlobalDsl.
      def initialize(script)
        @script = script
      end

      # Get the Rscons build directory path.
      #
      # @return [String]
      #   Rscons build directory path.
      def build_dir
        Rscons.application.build_dir
      end

      # Return a list of paths matching the specified pattern(s).
      #
      # A pattern can contain a "/**" component to recurse through directories.
      # If the pattern ends with "/**" then only the recursive list of
      # directories will be returned.
      #
      # Examples:
      # - "src/**": return all directories under "src", recursively (including
      #   "src" itself).
      # - "src/**/*": return all files and directories recursively under the src
      #   directory.
      # - "src/**/*.c": return all .c files recursively under the src directory.
      # - "dir/*/": return all directories in dir, but no files.
      #
      # @return [Array<String>] Paths matching the specified pattern(s).
      def glob(*patterns)
        require "pathname"
        patterns.reduce([]) do |result, pattern|
          if pattern.end_with?("/**")
            pattern += "/"
          end
          result += Dir.glob(pattern).map do |path|
            Pathname.new(path.gsub("\\", "/")).cleanpath.to_s
          end
        end.sort
      end

      # Download a file.
      #
      # @param url [String]
      #   URL.
      # @param dest [String]
      #   Path to where to save the file.
      # @param options [Hash]
      #   Options.
      # @option options [String] :sha256sum
      #   Expected file checksum.
      # @option options [Integer] :redirect_limit
      #   Maximum number of times to allow HTTP redirection (default 5).
      #
      # @return [void]
      def download(url, dest, options = {})
        options[:redirect_limit] ||= 5
        unless options[:redirected]
          if File.exist?(dest) && options[:sha256sum]
            if Digest::SHA2.hexdigest(File.binread(dest)) == options[:sha256sum]
              # Destination file already exists and has the expected checksum.
              return
            end
          end
        end
        uri = URI(url)
        use_ssl = url.start_with?("https://")
        response = nil
        socketerror_message = ""
        digest = Digest::SHA2.new
        begin
          Net::HTTP.start(uri.host, uri.port, use_ssl: use_ssl) do |http|
            File.open(dest, "wb") do |fh|
              response = http.get(uri.request_uri) do |data|
                fh.write(data)
                digest << data
              end
            end
          end
        rescue SocketError => e
          raise RsconsError.new("Error downloading #{dest}: #{e.message}")
        end
        if response.is_a?(Net::HTTPRedirection)
          if options[:redirect_limit] == 0
            raise RsconsError.new("Redirect limit reached when downloading #{dest}")
          else
            return download(response["location"], dest, options.merge(redirect_limit: options[:redirect_limit] - 1, redirected: true))
          end
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise RsconsError.new("Error downloading #{dest}")
        end
        if options[:sha256sum] && options[:sha256sum] != digest.hexdigest
          raise RsconsError.new("Unexpected checksum on #{dest}")
        end
      end

      # Create an environment.
      #
      # @overload env(name, options)
      #   @param name [String]
      #     Environment name. This determines the folder name used to store all
      #     environment build files under the top-level build directory.
      #   @param options [Hash]
      #   @option options [Symbol] :echo
      #     :command, :short, or :off (default :short)
      #   @option options [Boolean] :exclude_builders
      #     Whether to omit adding default builders (default false)
      #   @option options [String, Array<String>] :use
      #     Use flag(s). If specified, any configuration flags which were saved
      #     with a corresponding `:use` value will be applied to this
      #     Environment.
      #
      # @overload env(options)
      #   @param options [Hash]
      #   @option options [Symbol] :echo
      #     :command, :short, or :off (default :short)
      #   @option options [Boolean] :exclude_builders
      #     Whether to omit adding default builders (default false)
      #   @option options [String, Array<String>] :use
      #     Use flag(s). If specified, any configuration flags which were saved
      #     with a corresponding `:use` value will be applied to this
      #     Environment.
      #
      # If a block is given it is immediately executed and passed the newly
      # created Environment object as an argument.
      # If the Environment is created in task context, the +process+ method is
      # immediately called.
      # Otherwise, the Environment is not processed until the task execution
      # phase.
      #
      # @yield [env]
      # @yieldparam env [Environment]
      #   The created environment.
      def env(*args, &block)
        Rscons.application.check_configure
        e = Environment.new(*args, &block)
        if Rscons.application.task_execution_phase?
          e.process
        end
        e
      end

      # Construct a task parameter.
      #
      # @param name [String]
      #   Param name.
      # @param value [String, nil]
      #   Param value.
      # @param takes_arg [String]
      #   Whether the parameter takes an argument.
      # @param description [String]
      #   Param description.
      def param(name, value, takes_arg, description)
        Task::Param.new(name, value, takes_arg, description)
      end

      # Return path components from the PATH variable.
      #
      # @return [Array<String>]
      #   Path components from the PATH variable.
      def path_components
        ENV["PATH"].split(File::PATH_SEPARATOR)
      end

      # Prepend a path component to the PATH variable.
      #
      # @param path [String]
      #   Path to prepend.
      #
      # @return [void]
      def path_prepend(path)
        path_set([File.expand_path(path)] + path_components)
      end

      # Append a path component to the PATH variable.
      #
      # @param path [String]
      #   Path to append.
      #
      # @return [void]
      def path_append(path)
        path_set(path_components + [File.expand_path(path)])
      end

      # Set the PATH variable.
      #
      # @param new_path [String, Array<String>]
      #   New PATH variable value as an array or string.
      #
      # @return [void]
      def path_set(new_path)
        if new_path.is_a?(Array)
          new_path = new_path.join(File::PATH_SEPARATOR)
        end
        ENV["PATH"] = new_path
      end

      # Invoke rscons in a subprocess for a subsidiary Rsconscript file.
      #
      # @param path [String]
      #   Path to subsidiary Rsconscript to execute, or path to subsidiary
      #   directory to run rscons in.
      # @param args[Array<String>]
      #   Arguments to pass to rscons subprocess.
      def rscons(path, *args)
        rscons_path = File.expand_path($0)
        path = File.expand_path(path)
        if File.directory?(path)
          command = [*args]
          dir = path
        else
          command = ["-f", path, *args]
          dir = File.dirname(path)
        end
        if File.exist?("#{dir}/rscons")
          rscons_path = "#{dir}/rscons"
        end
        command = [rscons_path] + command
        print_dir = dir != "." && dir != File.expand_path(Dir.pwd)
        if ENV["specs"] and not ENV["dist_specs"] # specs
          command = ["ruby", $LOAD_PATH.map {|p| ["-I", p]}, command].flatten # specs
        end # specs
        puts "rscons: Entering directory '#{dir}'" if print_dir
        result = system(*command, chdir: dir)
        puts "rscons: Leaving directory '#{dir}'" if print_dir
        unless result
          raise RsconsError.new("Failed command: " + command.join(" "))
        end
      end

      # Execute a shell command, exiting on failure.
      # The behavior to exit on failure is suppressed if the +:continue+
      # option is given.
      #
      # @overload sh(command, options = {})
      #   @param command [String, Array<String>]
      #     Command to execute. The command is executed and interpreted by the
      #     system shell when given as a single string. It is not passed to the
      #     system shell if the array size is greater than 1.
      #   @param options [Hash]
      #     Options.
      #   @option options [Boolean] :continue
      #     If set to +true+, rscons will continue executing afterward, even if
      #     the command fails.
      #
      # @overload sh(*command, options = {})
      #   @param command [String, Array<String>]
      #     Command to execute. The command is executed and interpreted by the
      #     system shell when given as a single string. It is not passed to the
      #     system shell if the array size is greater than 1.
      #   @param options [Hash]
      #     Options.
      #   @option options [Boolean] :continue
      #     If set to +true+, rscons will continue executing afterward, even if
      #     the command fails.
      def sh(*command)
        options = {}
        if command.last.is_a?(Hash)
          options = command.slice!(-1)
        end
        continue = options.delete(:continue)
        if command.size == 1 && command[0].is_a?(Array)
          command = command[0]
        end
        if Rscons.application.verbose
          if command.size > 1
            puts Util.command_to_s(command)
          else
            puts command[0]
          end
        end
        begin
          system(*command, options.merge(exception: true))
        rescue StandardError => e
          message = "#{e.backtrace[2]}: #{e.message}"
          if continue
            Ansi.write($stderr, :red, message, :reset, "\n")
          else
            raise RsconsError.new(message)
          end
        end
      end

      # Create or modify a task.
      #
      # @overload task(name, options = {}, &block)
      #   @param name [String]
      #     Task name.
      #   @param options [Hash]
      #     Optional task attributes.
      #   @option options [Boolean] :autoconf
      #     Whether to automatically configure before running this task
      #     (default: true).
      #   @option options [String] :desc
      #     Description for the task.
      #   @option options [Array<String>] :depends
      #     Dependencies of the task.
      #   @option options [Array<Task::Param>] :params
      #     Task parameter definitions.
      #
      # The action block given will be invoked by Rscons when the task
      # executes. It will be passed two arguments:
      #   1) The Task object.
      #   2) A Hash of task parameter names and values.
      def task(*args, &block)
        Util.task(*args, &block)
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
        Rscons.application.variant(name, options)
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
        Rscons.application.variant_enabled?(variant_name)
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
        Rscons.application.variant_group(*args, &block)
      end

      # Iterate through enabled variants.
      #
      # The given block is called for each combination of enabled variants
      # across the defined variant groups.
      def with_variants(&block)
        Rscons.application.enable_variants
        Rscons.application.with_variants(&block)
      end

      [
        :cd,
        :chmod,
        :chmod_R,
        :chown,
        :chown_R,
        :cp,
        :cp_lr,
        :cp_r,
        :install,
        :ln,
        :ln_s,
        :ln_sf,
        :mkdir,
        :mkdir_p,
        :mv,
        :pwd,
        :rm,
        :rm_f,
        :rm_r,
        :rm_rf,
        :rmdir,
        :touch,
      ].each do |method|
        define_method(method) do |*args, **kwargs, &block|
          FileUtils.__send__(method, *args, **kwargs, &block)
        end
      end

    end

    # Top-level DSL available to the Rsconscript.
    class TopLevelDsl < GlobalDsl
      # Set the project name.
      #
      # @param project_name [String]
      #   Project name.
      def project_name(project_name)
        @script.project_name = project_name
      end

      # Set whether to automatically configure (default true).
      #
      # @param autoconf [Boolean]
      #   Whether to automatically configure.
      def autoconf(autoconf)
        @script.autoconf = autoconf
      end

      # Shortcut methods to create task blocks for special tasks.
      [
        :clean,
        :distclean,
        :configure,
        :default,
        :install,
        :uninstall,
      ].each do |method_name|
        define_method(method_name) do |*args, &block|
          task(method_name.to_s, *args, &block)
        end
      end
    end

    # DSL available to the 'configure' block.
    class ConfigureDsl < GlobalDsl
      # Create a ConfigureDsl.
      #
      # @param script [Script]
      #   The Script being evaluated.
      # @param configure_op [ConfigureOp]
      #   The configure operation object.
      def initialize(script, configure_op)
        super(script)
        @configure_op = configure_op
      end

      [
        :check_c_compiler,
        :check_cxx_compiler,
        :check_d_compiler,
        :check_cfg,
        :check_c_header,
        :check_cxx_header,
        :check_d_import,
        :check_lib,
        :check_program,
      ].each do |method_name|
        define_method(method_name) do |*args|
          @configure_op.__send__(method_name, *args)
        end
      end

      # Perform a custom configuration check.
      #
      # @param message [String]
      #   Custom configuration check message (e.g. "Checking for foo").
      #   rscons will add "... " to the end of the message.
      # @yieldparam configure_op [ConfigureOp]
      #   {ConfigureOp} object.
      # @return [void]
      def custom_check(message, &block)
        $stdout.write(message + "... ")
        block[@configure_op]
      end
    end

    # @return [String, nil]
    #   Project name.
    attr_accessor :project_name

    # @return [Boolean]
    #   Whether to autoconfigure if the user does not explicitly configure
    #   before calling a normal task (default: true).
    attr_accessor :autoconf

    # Construct a Script.
    def initialize
      @autoconf = true
      TopLevelDsl.new(self).instance_eval do
        task("clean",
             desc: "Remove build artifacts (but not configuration)",
             autoconf: false) do
          Rscons.application.clean
        end
        task("configure",
             desc: "Configure the project",
             autoconf: false,
             params: [param("prefix", "/usr/local", true, "Set installation prefix (default: /usr/local)")])
        task("distclean",
             desc: "Remove build directory and configuration",
             autoconf: false) do
          Rscons.application.distclean
        end
        task("install",
             desc: "Install project to configured installation prefix")
        task("uninstall",
             desc: "Uninstall project",
             autoconf: false) do
          Rscons.application.uninstall
        end
      end
    end

    # Load a script from the specified file.
    #
    # @param path [String]
    #   File name of the rscons script to load.
    #
    # @return [void]
    def load(path)
      Rscons.application.silent_configure = true
      script_contents = File.read(path, mode: "rb")
      TopLevelDsl.new(self).instance_eval(script_contents, path, 1)
    end

    # Perform configure action.
    def configure(configure_op)
      cdsl = ConfigureDsl.new(self, configure_op)
      configure_task = Task["configure"]
      configure_task.actions.each do |action|
        cdsl.instance_exec(configure_task, configure_task.param_values, &action)
      end
    end

  end

end
