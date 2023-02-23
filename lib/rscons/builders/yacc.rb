module Rscons
  module Builders
    # Build a source file given a yacc input file.
    #
    # Examples::
    #   env.Yacc("parser.c", "parser.y")
    #   env.Yacc("parser.cc", "parser.yy")
    class Yacc < Builder

      # Run the builder to produce a build target.
      def run(options)
        if @command
          finalize_command
        else
          @vars["_TARGET"] = @target
          @vars["_SOURCES"] = @sources
          command = @env.build_command("${YACC_CMD}", @vars)
          standard_command("Generating parser source from <source>#{Util.short_format_paths(@sources)}<reset> => <target>#{@target}<reset>", command)
        end
      end

    end
  end
end
