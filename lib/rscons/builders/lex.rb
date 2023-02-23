module Rscons
  module Builders
    # Build a source file given a lex input file.
    #
    # Examples::
    #   env.Lex("lex.c", "parser.l")
    #   env.Lex("lex.cc", "parser.ll")
    class Lex < Builder

      # Run the builder to produce a build target.
      def run(options)
        if @command
          finalize_command
        else
          @vars["_TARGET"] = @target
          @vars["_SOURCES"] = @sources
          command = @env.build_command("${LEX_CMD}", @vars)
          standard_command("Generating lexer source from <source>#{Util.short_format_paths(@sources)}<reset> => <target>#{@target}<reset>", command)
        end
      end

    end
  end
end
