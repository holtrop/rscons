module Rscons
  module Builders
    # The Precompile builder generates .di interface files from .d source files
    # for D.
    class Precompile < Builder

      # Run the builder to produce a build target.
      def run(options)
        if @command
          finalize_command
        else
          if @sources.find {|s| s.end_with?(*@env.expand_varref("${DSUFFIX}", @vars))}
            pcc = @env.expand_varref("${DC}")
            if pcc =~ /ldc/
              dpc_cmd = "${DPC_CMD:ldc}"
            else
              dpc_cmd = "${DPC_CMD:gdc}"
            end
            @vars["_TARGET"] = @target
            @vars["_SOURCES"] = @sources
            command = @env.build_command(dpc_cmd, @vars)
            standard_command("Precompile <source>#{Util.short_format_paths(@sources)}<reset>", command)
          end
        end
      end

    end
  end
end
