module Rscons
  module Builders
    # Run the "size" utility on an executable and store its results in the
    # target file.
    #
    # Examples::
    #   env.Size("^/project.size", "^/project.elf")
    class Size < Builder

      # Run the builder to produce a build target.
      def run(options)
        if @command
          finalize_command
        else
          @vars["_SOURCES"] = @sources
          command = @env.build_command("${SIZECMD}", @vars)
          standard_command("Size <source>#{Util.short_format_paths(@sources)}<reset> => <target>#{@target}<reset>", command, stdout: @target)
        end
      end

    end
  end
end
