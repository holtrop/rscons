require "pathname"

module Rscons
  module Builders
    # The Copy builder copies files/directories to new locations.
    class Copy < Builder

      # Construct builder.
      def initialize(*args)
        super
        @install_builder = self.class.name == "Install"
        @nop = @install_builder && !Rscons.application.operation("install")
      end

      # Return whether the builder is a no-op.
      #
      # @return [Boolean]
      #   Whether the builder is a no-op.
      def nop?
        @nop
      end

      # Run the builder to produce a build target.
      def run(options)
        if @nop
          true
        else
          target_is_dir = (@sources.length > 1) ||
                          Dir.exists?(@sources.first) ||
                          Dir.exists?(@target)
          outdir = target_is_dir ? @target : File.dirname(@target)
          # Collect the list of files to copy over.
          file_map = {}
          if target_is_dir
            @sources.each do |src|
              if Dir.exists? src
                Dir.glob("#{src}/**/*", File::FNM_DOTMATCH).select do |f|
                  File.file?(f)
                end.each do |subfile|
                  subpath = Pathname.new(subfile).relative_path_from(Pathname.new(src)).to_s
                  file_map[subfile] = "#{outdir}/#{subpath}"
                end
              else
                file_map[src] = "#{outdir}/#{File.basename(src)}"
              end
            end
          else
            file_map[sources.first] = target
          end
          printed_message = false
          file_map.each do |src, dest|
            # Check the cache and copy if necessary
            unless @cache.up_to_date?(dest, :Copy, [src], @env)
              unless printed_message
                message = "#{name} <source>#{Util.short_format_paths(@sources)}<reset> => <target>#{@target}<reset>"
                print_run_message(message, nil)
                printed_message = true
              end
              @cache.mkdir_p(File.dirname(dest), install: @install_builder)
              FileUtils.rm_f(dest)
              FileUtils.cp(src, dest, :preserve => true)
            end
            @cache.register_build(dest, :Copy, [src], @env, install: @install_builder)
          end
          (target_is_dir ? Dir.exists?(@target) : File.exists?(@target)) ? true : false
        end
      end

    end

    # The Install builder is identical to the Copy builder.
    class Install < Copy; end

  end
end
