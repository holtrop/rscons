module Rscons
  module Builders
    # A default Rscons builder that knows how to link object files into an
    # executable program.
    class Program < Builder
      def default_variables(env)
        {
          'OBJSUFFIX' => '.o',
          'PROGSUFFIX' => (Object.const_get("RUBY_PLATFORM") =~ /mingw|cygwin/ ? ".exe" : ""),
          'LD' => nil,
          'LIBSUFFIX' => '.a',
          'LDFLAGS' => [],
          'LIBPATH' => [],
          'LIBDIRPREFIX' => '-L',
          'LIBLINKPREFIX' => '-l',
          'LIBS' => [],
          'LDCMD' => ['${LD}', '-o', '${_TARGET}', '${LDFLAGS}', '${_SOURCES}', '${LIBDIRPREFIX}${LIBPATH}', '${LIBLINKPREFIX}${LIBS}']
        }
      end

      def create_build_target(options)
        my_options = options.dup
        unless my_options[:target] =~ /\./
          my_options[:target] += options[:env].expand_varref("${PROGSUFFIX}")
        end
        super(my_options)
      end

      def run(target, sources, cache, env, vars)
        # build sources to linkable objects
        objects = env.build_sources(sources, env.expand_varref(["${OBJSUFFIX}", "${LIBSUFFIX}"], vars).flatten, cache, vars)
        return false unless objects
        ld = env.expand_varref("${LD}", vars)
        ld = if ld != ""
               ld
             elsif sources.find {|s| s.end_with?(*env.expand_varref("${DSUFFIX}", vars))}
               "${DC}"
             elsif sources.find {|s| s.end_with?(*env.expand_varref("${CXXSUFFIX}", vars))}
               "${CXX}"
             else
               "${CC}"
             end
        vars = vars.merge({
          '_TARGET' => target,
          '_SOURCES' => objects,
          'LD' => ld,
        })
        command = env.build_command("${LDCMD}", vars)
        standard_build("LD #{target}", target, command, objects, env, cache)
      end
    end
  end
end
