require "fileutils"
require "set"
require "shellwords"

module Rscons
  # The Environment class is the main programmatic interface to Rscons. It
  # contains a collection of construction variables, options, builders, and
  # rules for building targets.
  class Environment
    # @return [Hash] Set of !{"builder_name" => builder_object} pairs.
    attr_reader :builders

    # :command, :short, or :off
    attr_accessor :echo

    # @return [String, nil] The build root.
    attr_reader :build_root

    # Set the build root.
    #
    # @param build_root [String] The build root.
    def build_root=(build_root)
      @build_root = build_root
      @build_root.gsub!('\\', '/') if @build_root
    end

    # Create an Environment object.
    #
    # @param options [Hash]
    # @option options [Symbol] :echo
    #   :command, :short, or :off (default :short)
    # @option options [String] :build_root
    #   Build root directory (default nil)
    # @option options [Boolean] :exclude_builders
    #   Whether to omit adding default builders (default false)
    #
    # If a block is given, the Environment object is yielded to the block and
    # when the block returns, the {#process} method is automatically called.
    def initialize(options = {})
      @varset = VarSet.new
      @targets = {}
      @user_deps = {}
      @builders = {}
      @build_dirs = []
      @build_hooks = {pre: [], post: []}
      unless options[:exclude_builders]
        DEFAULT_BUILDERS.each do |builder_class_name|
          builder_class = Builders.const_get(builder_class_name)
          builder_class or raise "Could not find builder class #{builder_class_name}"
          add_builder(builder_class.new)
        end
      end
      @echo = options[:echo] || :short
      @build_root = options[:build_root]

      if block_given?
        yield self
        self.process
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
    # - :build_root to clone the build root (off by default)
    # - :build_dirs to clone the build directories (off by default)
    # - :build_hooks to clone the build hooks (off by default)
    #
    # If a block is given, the Environment object is yielded to the block and
    # when the block returns, the {#process} method is automatically called.
    #
    # Any options that #initialize receives can also be specified here.
    #
    # @return a new {Environment} object.
    def clone(options = {})
      clone = options[:clone] || Set[:variables, :builders]
      clone = Set[:variables, :builders, :build_root, :build_dirs, :build_hooks] if clone == :all
      clone = Set[] if clone == :none
      clone = Set.new(clone) if clone.is_a?(Array)
      clone.delete(:builders) if options[:exclude_builders]
      env = self.class.new(
        echo: options[:echo] || @echo,
        build_root: options[:build_root],
        exclude_builders: true)
      if clone.include?(:builders)
        @builders.each do |builder_name, builder|
          env.add_builder(builder)
        end
      end
      env.append(@varset) if clone.include?(:variables)
      env.build_root = @build_root if clone.include?(:build_root)
      if clone.include?(:build_dirs)
        @build_dirs.each do |src_dir, obj_dir|
          env.build_dir(src_dir, obj_dir)
        end
      end
      if clone.include?(:build_hooks)
        @build_hooks[:pre].each do |build_hook_block|
          env.add_build_hook(&build_hook_block)
        end
        @build_hooks[:post].each do |build_hook_block|
          env.add_post_build_hook(&build_hook_block)
        end
      end

      if block_given?
        yield env
        env.process
      end
      env
    end

    # Add a {Builder} object to the Environment.
    #
    # @param builder [Builder] The {Builder} object to add.
    #
    # @return [void]
    def add_builder(builder)
      @builders[builder.name] = builder
      var_defs = builder.default_variables(self)
      if var_defs
        var_defs.each_pair do |var, val|
          @varset[var] ||= val
        end
      end
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
    # @since 1.7.0
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

    # Specify a build directory for this Environment.
    #
    # Source files from src_dir will produce object files under obj_dir.
    #
    # @param src_dir [String, Regexp] Path to the source directory.
    # @param obj_dir [String] Path to the object directory.
    #
    # @return [void]
    def build_dir(src_dir, obj_dir)
      if src_dir.is_a?(String)
        src_dir = src_dir.gsub("\\", "/").sub(%r{/*$}, "")
      end
      @build_dirs << [src_dir, obj_dir]
    end

    # Return the file name to be built from +source_fname+ with suffix
    # +suffix+.
    #
    # This method takes into account the Environment's build directories.
    #
    # @param source_fname [String] Source file name.
    # @param suffix [String] Suffix, including "." if desired.
    #
    # @return [String]
    #   The file name to be built from +source_fname+ with suffix +suffix+.
    def get_build_fname(source_fname, suffix)
      build_fname = Rscons.set_suffix(source_fname, suffix).gsub('\\', '/')
      found_match = @build_dirs.find do |src_dir, obj_dir|
        if src_dir.is_a?(Regexp)
          build_fname.sub!(src_dir, obj_dir)
        else
          build_fname.sub!(%r{^#{src_dir}/}, "#{obj_dir}/")
        end
      end
      if @build_root and not found_match
        unless Rscons.absolute_path?(source_fname) or build_fname.start_with?("#{@build_root}/")
          build_fname = "#{@build_root}/#{build_fname}"
        end
      end
      build_fname.gsub!('\\', '/')
      build_fname
    end

    # Access a construction variable or environment option.
    #
    # @see VarSet#[]
    def [](*args)
      @varset.send(:[], *args)
    end

    # Set a construction variable or environment option.
    #
    # @see VarSet#[]=
    def []=(*args)
      @varset.send(:[]=, *args)
    end

    # Add a set of construction variables or environment options.
    #
    # @see VarSet#append
    def append(*args)
      @varset.append(*args)
    end

    # Build all build targets specified in the Environment.
    #
    # When a block is passed to Environment.new, this method is automatically
    # called after the block returns.
    #
    # @return [void]
    def process
      expand_paths!
      while @targets.size > 0
        targets = @targets
        @targets = {}
        cache = Cache.instance
        cache.clear_checksum_cache!
        targets_processed = {}
        process_target = proc do |target|
          targets_processed[target] ||= begin
            targets[target][:sources].each do |src|
              if targets.include?(src) and not targets_processed.include?(src)
                process_target.call(src)
              end
            end
            result = run_builder(targets[target][:builder],
                                 target,
                                 targets[target][:sources],
                                 cache,
                                 targets[target][:vars] || {})
            unless result
              raise BuildError.new("Failed to build #{target}")
            end
            result
          end
        end
        begin
          targets.each do |target, target_params|
            process_target.call(target)
          end
        ensure
          cache.write
        end
      end
    end

    # Clear all targets registered for the Environment.
    def clear_targets
      @targets = {}
    end

    # Expand a construction variable reference.
    #
    # @param varref [Array, String] Variable reference to expand.
    # @param extra_vars [Hash, VarSet]
    #   Extra variables to use in addition to (or replace) the Environment's
    #   construction variables when expanding the variable reference.
    #
    # @return [Array, String] Expansion of the variable reference.
    def expand_varref(varref, extra_vars = nil)
      vars = if extra_vars.nil?
               @varset
             else
               @varset.merge(extra_vars)
             end
      lambda_args = [env: self, vars: vars]
      vars.expand_varref(varref, lambda_args)
    end
    alias_method :build_command, :expand_varref

    # Execute a builder command.
    #
    # @param short_desc [String] Message to print if the Environment's echo
    #   mode is set to :short
    # @param command [Array] The command to execute.
    # @param options [Hash] Optional options, possible keys:
    #   - :env - environment Hash to pass to Kernel#system.
    #   - :options - options Hash to pass to Kernel#system.
    #
    # @return [true,false,nil] Return value from Kernel.system().
    def execute(short_desc, command, options = {})
      print_command = proc do
        puts command.map { |c| c =~ /\s/ ? "'#{c}'" : c }.join(' ')
      end
      if @echo == :command
        print_command.call
      elsif @echo == :short
        puts short_desc
      end
      env_args = options[:env] ? [options[:env]] : []
      options_args = options[:options] ? [options[:options]] : []
      system(*env_args, *Rscons.command_executer, *command, *options_args).tap do |result|
        unless result or @echo == :command
          $stdout.write "Failed command was: "
          print_command.call
        end
      end
    end

    # Define a build target.
    #
    # @param method [Symbol] Method name.
    # @param args [Array] Method arguments.
    #
    # @return [BuildTarget]
    #   The {BuildTarget} object registered, if the method called is a
    #   {Builder}.
    def method_missing(method, *args)
      if @builders.has_key?(method.to_s)
        target, sources, vars, *rest = args
        unless vars.nil? or vars.is_a?(Hash) or vars.is_a?(VarSet)
          raise "Unexpected construction variable set: #{vars.inspect}"
        end
        sources = Array(sources)
        builder = @builders[method.to_s]
        build_target = builder.create_build_target(env: self, target: target, sources: sources)
        add_target(build_target.to_s, builder, sources, vars, rest)
        build_target
      else
        super
      end
    end

    # Add a build target.
    #
    # @param target [String] Build target file name.
    # @param builder [Builder] The {Builder} to use to build the target.
    # @param sources [Array<String>] Source file name(s).
    # @param vars [Hash] Construction variable overrides.
    # @param args [Object] Any extra arguments passed to the {Builder}.
    #
    # @return [void]
    def add_target(target, builder, sources, vars, args)
      @targets[target] = {
        builder: builder,
        sources: sources,
        vars: vars,
        args: args,
      }
    end

    # Manually record a given target as depending on the specified files.
    #
    # @param target [String,BuildTarget] Target file.
    # @param user_deps [Array<String>] Dependency files.
    #
    # @return [void]
    def depends(target, *user_deps)
      target = expand_varref(target.to_s)
      user_deps = user_deps.map {|ud| expand_varref(ud)}
      @user_deps[target] ||= []
      @user_deps[target] = (@user_deps[target] + user_deps).uniq
    end

    # Return the list of user dependencies for a given target.
    #
    # @param target [String] Target file name.
    #
    # @return [Array<String>,nil]
    #   List of user-specified dependencies for the target, or nil if none were
    #   specified.
    def get_user_deps(target)
      @user_deps[target]
    end

    # Build a list of source files into files containing one of the suffixes
    # given by suffixes.
    #
    # This method is used internally by Rscons builders.
    #
    # @param sources [Array] List of source files to build.
    # @param suffixes [Array] List of suffixes to try to convert source files into.
    # @param cache [Cache] The Cache.
    # @param vars [Hash] Extra variables to pass to the builder.
    #
    # @return [Array<String>] List of the converted file name(s).
    def build_sources(sources, suffixes, cache, vars)
      sources.map do |source|
        if source.end_with?(*suffixes)
          source
        else
          converted = nil
          suffixes.each do |suffix|
            converted_fname = get_build_fname(source, suffix)
            builder = @builders.values.find { |b| b.produces?(converted_fname, source, self) }
            if builder
              converted = run_builder(builder, converted_fname, [source], cache, vars)
              return nil unless converted
              break
            end
          end
          converted or raise "Could not find a builder to handle #{source.inspect}."
        end
      end
    end

    # Invoke a builder to build the given target based on the given sources.
    #
    # @param builder [Builder] The Builder to use.
    # @param target [String] The target output file.
    # @param sources [Array] List of source files.
    # @param cache [Cache] The Cache.
    # @param vars [Hash] Extra variables to pass to the builder.
    #
    # @return [String,false] Return value from the {Builder}'s +run+ method.
    def run_builder(builder, target, sources, cache, vars)
      vars = @varset.merge(vars)
      call_build_hooks = lambda do |sec|
        @build_hooks[sec].each do |build_hook_block|
          build_operation = {
            builder: builder,
            target: target,
            sources: sources,
            vars: vars,
            env: self,
          }
          build_hook_block.call(build_operation)
        end
      end
      call_build_hooks[:pre]
      rv = builder.run(target, sources, cache, self, vars)
      call_build_hooks[:post] if rv
      rv
    end

    # Expand a path to be relative to the Environment's build root.
    #
    # Paths beginning with "^/" are expanded by replacing "^" with the
    # Environment's build root.
    #
    # @param path [String] The path to expand.
    #
    # @return [String] The expanded path.
    def expand_path(path)
      path.sub(%r{^\^(?=[\\/])}, @build_root)
    end

    # Execute a command using the system shell.
    #
    # The shell is automatically determined but can be overridden by the SHELL
    # construction variable. If the SHELL construction variable is specified,
    # the flag to pass to the shell is automatically dtermined but can be
    # overridden by the SHELLFLAG construction variable.
    #
    # @param command [String] Command to execute.
    #
    # @return [String] The command's standard output.
    def shell(command)
      shell_cmd =
        if self["SHELL"]
          flag = self["SHELLFLAG"] || (self["SHELL"] == "cmd" ? "/c" : "-c")
          [self["SHELL"], flag]
        else
          Rscons.get_system_shell
        end
      IO.popen([*shell_cmd, command]) do |io|
        io.read
      end
    end

    # @!method parse_flags(flags)
    # @!method parse_flags!(flags)
    #
    # Parse command-line flags for compilation/linking options into separate
    # construction variables.
    #
    # The parsed construction variables are returned in a Hash instead of
    # merging them directly to the Environment. They can be merged with
    # {#merge_flags}. The {#parse_flags!} version immediately merges the parsed
    # flags as well.
    #
    # Example:
    #   # Import FreeType build options
    #   env.parse_flags!("!freetype-config --cflags --libs")
    #
    # @param flags [String]
    #   String containing the flags to parse, or if the flags string begins
    #   with "!", a shell command to execute using {#shell} to obtain the
    #   flags to parse.
    #
    # @return [Hash] Set of construction variables to append.
    def parse_flags(flags)
      if flags =~ /^!(.*)$/
        flags = shell($1)
      end
      rv = {}
      words = Shellwords.split(flags)
      skip = false
      words.each_with_index do |word, i|
        if skip
          skip = false
          next
        end
        append = lambda do |var, val|
          rv[var] ||= []
          rv[var] += val
        end
        handle = lambda do |var, val|
          if val.nil? or val.empty?
            val = words[i + 1]
            skip = true
          end
          if val and not val.empty?
            append[var, [val]]
          end
        end
        if word == "-arch"
          if val = words[i + 1]
            append["CCFLAGS", ["-arch", val]]
            append["LDFLAGS", ["-arch", val]]
          end
          skip = true
        elsif word =~ /^#{self["CPPDEFPREFIX"]}(.*)$/
          handle["CPPDEFINES", $1]
        elsif word == "-include"
          if val = words[i + 1]
            append["CCFLAGS", ["-include", val]]
          end
          skip = true
        elsif word == "-isysroot"
          if val = words[i + 1]
            append["CCFLAGS", ["-isysroot", val]]
            append["LDFLAGS", ["-isysroot", val]]
          end
          skip = true
        elsif word =~ /^#{self["INCPREFIX"]}(.*)$/
          handle["CPPPATH", $1]
        elsif word =~ /^#{self["LIBLINKPREFIX"]}(.*)$/
          handle["LIBS", $1]
        elsif word =~ /^#{self["LIBDIRPREFIX"]}(.*)$/
          handle["LIBPATH", $1]
        elsif word == "-mno-cygwin"
          append["CCFLAGS", [word]]
          append["LDFLAGS", [word]]
        elsif word == "-mwindows"
          append["LDFLAGS", [word]]
        elsif word == "-pthread"
          append["CCFLAGS", [word]]
          append["LDFLAGS", [word]]
        elsif word =~ /^-std=/
          append["CFLAGS", [word]]
        elsif word =~ /^-Wa,(.*)$/
          append["ASFLAGS", $1.split(",")]
        elsif word =~ /^-Wl,(.*)$/
          append["LDFLAGS", $1.split(",")]
        elsif word =~ /^-Wp,(.*)$/
          append["CPPFLAGS", $1.split(",")]
        elsif word.start_with?("-")
          append["CCFLAGS", [word]]
        elsif word.start_with?("+")
          append["CCFLAGS", [word]]
          append["LDFLAGS", [word]]
        else
          append["LIBS", [word]]
        end
      end
      rv
    end

    def parse_flags!(flags)
      flags = parse_flags(flags)
      merge_flags(flags)
      flags
    end

    # Merge construction variable flags into this Environment's construction
    # variables.
    #
    # This method does the same thing as {#append}, except that Array values in
    # +flags+ are appended to the end of Array construction variables instead
    # of replacing their contents.
    #
    # @param flags [Hash]
    #   Set of construction variables to merge into the current Environment.
    #   This can be the value (or a modified version) returned by
    #   {#parse_flags}.
    #
    # @return [void]
    def merge_flags(flags)
      flags.each_pair do |key, val|
        if self[key].is_a?(Array) and val.is_a?(Array)
          self[key] += val
        else
          self[key] = val
        end
      end
    end

    private

    # Expand target and source paths before invoking builders.
    #
    # This method expand construction variable references in the target and
    # source file names before passing them to the builder. It also expands
    # "^/" prefixes to the Environment's build root if a build root is defined.
    #
    # @return [void]
    def expand_paths!
      @targets = @targets.reduce({}) do |result, (target, target_params)|
        sources = target_params[:sources].map do |source|
          source = expand_path(source) if @build_root
          expand_varref(source)
        end
        target = expand_path(target) if @build_root
        target = expand_varref(target)
        result[target] = target_params.merge(sources: sources)
        result
      end
    end

    # Parse dependencies for a given target from a Makefile.
    #
    # This method is used internally by Rscons builders.
    #
    # @param mf_fname [String] File name of the Makefile to read.
    # @param target [String] Name of the target to gather dependencies for.
    #
    # @return [Array<String>] Paths of dependency files.
    def self.parse_makefile_deps(mf_fname, target)
      deps = []
      buildup = ''
      File.read(mf_fname).each_line do |line|
        if line =~ /^(.*)\\\s*$/
          buildup += ' ' + $1
        else
          buildup += ' ' + line
          if buildup =~ /^(.*): (.*)$/
            mf_target, mf_deps = $1.strip, $2
            if mf_target == target
              deps += mf_deps.split(' ').map(&:strip)
            end
          end
          buildup = ''
        end
      end
      deps
    end
  end
end
