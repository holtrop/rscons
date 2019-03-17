module Rscons
  module Builders
    # A default Rscons builder that knows how to link object files into a
    # shared library.
    class SharedLibrary < Builder

      # Create an instance of the Builder to build a target.
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
        @objects = @sources.map do |source|
          if source.end_with?(*suffixes)
            source
          else
            @env.register_dependency_build(@target, source, suffixes.first, @vars, SharedObject)
          end
        end
      end

      # Run the builder to produce a build target.
      def run(options)
        if @command
          finalize_command(sources: @objects)
          true
        else
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
          command = @env.build_command("${SHLDCMD}", @vars)
          standard_command("Linking => #{@target}", command, sources: @objects)
        end
      end

    end
  end
end
