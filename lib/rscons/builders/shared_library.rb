module Rscons
  module Builders
    # A default Rscons builder that knows how to link object files into a
    # shared library.
    class SharedLibrary < Builder

      Rscons.application.default_varset.append(
        'SHLIBPREFIX' => (RUBY_PLATFORM =~ /mingw/ ? '' : 'lib'),
        'SHLIBSUFFIX' => (RUBY_PLATFORM =~ /mingw/ ? '.dll' : '.so'),
        'SHLDFLAGS' => ['${LDFLAGS}', '-shared'],
        'SHLD' => nil,
        'SHLIBDIRPREFIX' => '-L',
        'SHLIBLINKPREFIX' => '-l',
        'SHLDCMD' => ['${SHLD}', '-o', '${_TARGET}', '${SHLDFLAGS}', '${_SOURCES}', '${SHLIBDIRPREFIX}${LIBPATH}', '${SHLIBLINKPREFIX}${LIBS}']
      )

      class << self
        # Return a set of build features that this builder provides.
        #
        # @return [Array<String>]
        #   Set of build features that this builder provides.
        def features
          %w[shared]
        end
      end

      # Create an instance of the Builder to build a target.
      #
      # @param options [Hash]
      #   Options.
      # @option options [String] :target
      #   Target file name.
      # @option options [Array<String>] :sources
      #   Source file name(s).
      # @option options [Environment] :env
      #   The Environment executing the builder.
      # @option options [Hash,VarSet] :vars
      #   Extra construction variables.
      def initialize(options)
        super(options)
        libprefix = @env.expand_varref("${SHLIBPREFIX}", @vars)
        unless File.basename(@target).start_with?(libprefix)
          @target = @target.sub!(%r{^(.*/)?([^/]+)$}, "\\1#{libprefix}\\2")
        end
        unless File.basename(@target)["."]
          @target += @env.expand_varref("${SHLIBSUFFIX}", @vars)
        end
        suffixes = @env.expand_varref(["${OBJSUFFIX}", "${LIBSUFFIX}"], @vars)
        # Register builders to build each source to an object file or library.
        @objects = @env.register_builds(@target, @sources, suffixes, @vars,
                                        features: %w[shared])
      end

      # Run the builder to produce a build target.
      #
      # @param options [Hash] Builder run options.
      #
      # @return [String,false]
      #   Name of the target file on success or false on failure.
      def run(options)
        ld = @env.expand_varref("${SHLD}", @vars)
        ld = if ld != ""
               ld
             elsif @sources.find {|s| s.end_with?(*@env.expand_varref("${DSUFFIX}", @vars))}
               "${SHDC}"
             elsif @sources.find {|s| s.end_with?(*@env.expand_varref("${CXXSUFFIX}", @vars))}
               "${SHCXX}"
             else
               "${SHCC}"
             end
        @vars["_TARGET"] = @target
        @vars["_SOURCES"] = @objects
        @vars["SHLD"] = ld
        options[:sources] = @objects
        command = @env.build_command("${SHLDCMD}", @vars)
        standard_threaded_build("SHLD #{@target}", @target, command, @objects, @env, @cache)
      end

      # Finalize a build.
      #
      # @param options [Hash]
      #   Finalize options.
      #
      # @return [String, nil]
      #   The target name on success or nil on failure.
      def finalize(options)
        standard_finalize(options)
      end

    end
  end
end
