require "rscons"
require "optparse"

# CLI usage string.
USAGE = <<EOF
Usage: #{$0} [global options] [operation] [operation options]

Global options:
  -F, --show-failure          Show failed command log from previous build and exit
  --version                   Show rscons version and exit
  -h, --help                  Show rscons help and exit
  -r COLOR, --color=COLOR     Set color mode (off, auto, force)
  -v, --verbose               Run verbosely

Operations:
  configure                   Configure the project
  build                       Build the project
  clean                       Remove build artifacts (but not configuration)
  distclean                   Remove build directory and configuration
  install                     Install project to installation destination
  uninstall                   Uninstall project from installation destination

Configure options:
  -b BUILD, --build=BUILD     Set build directory (default: build)
  --prefix=PREFIX             Set installation prefix (default: /usr/local)

Build options:
  -j N, --nthreads=N          Set number of threads (local default: #{Rscons.application.n_threads})

EOF

module Rscons
  # Command-Line Interface functionality.
  module Cli

    # Default files to look for to execute if none specified.
    DEFAULT_RSCONSCRIPTS = %w[Rsconscript Rsconscript.rb]

    class << self

      # Run the Rscons CLI.
      #
      # @param argv [Array]
      #   Command-line parameters.
      #
      # @return [void]
      def run(argv)
        argv = argv.dup
        begin
          exit run_toplevel(argv)
        rescue OptionParser::InvalidOption => io
          $stderr.puts io.message
          $stderr.puts USAGE
          exit 2
        end
      end

      private

      def add_global_options(opts)
        opts.on("-j NTHREADS") do |n_threads|
          Rscons.application.n_threads = n_threads.to_i
        end

        opts.on("-r", "--color MODE") do |color_mode|
          case color_mode
          when "off"
            Rscons.application.do_ansi_color = false
          when "force"
            Rscons.application.do_ansi_color = true
          end
        end

        opts.on("-v", "--verbose") do
          Rscons.application.verbose = true
        end
      end

      def run_toplevel(argv)
        rsconscript = nil
        do_help = false

        OptionParser.new do |opts|

          add_global_options(opts)

          opts.on("-f FILE") do |f|
            rsconscript = f
          end

          opts.on("-F", "--show-failure") do
            show_failure
            exit 0
          end

          opts.on("--version") do
            puts "Rscons version #{Rscons::VERSION}"
            exit 0
          end

          opts.on("-h", "--help") do
            do_help = true
          end

        end.order!(argv)

        # Retrieve the operation, or default to build.
        operation = argv.shift || "build"

        argv.each do |arg|
          if arg =~ /^([^=]+)=(.*)$/
            Rscons.application.vars[$1] = $2
          end
        end

        if rsconscript
          unless File.exists?(rsconscript)
            $stderr.puts "Cannot read #{rsconscript}"
            exit 1
          end
        else
          rsconscript = DEFAULT_RSCONSCRIPTS.find do |f|
            File.exists?(f)
          end
        end

        if rsconscript
          script = Script.new
          script.load(rsconscript)
        end

        if do_help
          puts USAGE
          exit 0
        end

        unless rsconscript
          $stderr.puts "Could not find the Rsconscript to execute."
          $stderr.puts "Looked for: #{DEFAULT_RSCONSCRIPTS.join(", ")}"
          exit 1
        end

        operation_options = parse_operation_args(operation, argv) || {}

        exit Rscons.application.run(operation, script, operation_options)
      end

      def parse_operation_args(operation, argv)
        options = {}
        OptionParser.new do |opts|
          add_global_options(opts)
          case operation
          when "configure"
            parse_configure_args(opts, argv, options)
          end
        end.order!(argv)
        options
      end

      def parse_configure_args(opts, argv, options)
        opts.on("-b", "--build DIR") do |build_dir|
          options[:build_dir] = build_dir
        end

        opts.on("--prefix PREFIX") do |prefix|
          options[:prefix] = prefix
        end
      end

      def show_failure
        failed_commands = Cache.instance["failed_commands"]
        failed_commands.each_with_index do |command, i|
          Ansi.write($stdout, :red, "Failed command (#{i + 1}/#{failed_commands.size}):", :reset, "\n")
          $stdout.puts Util.command_to_s(command)
        end
      end

    end
  end
end
