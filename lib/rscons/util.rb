module Rscons
  # A collection of stand-alone utility methods.
  module Util
    class << self

      # Return whether the given path is an absolute filesystem path.
      #
      # @param path [String] the path to examine.
      #
      # @return [Boolean] Whether the given path is an absolute filesystem path.
      def absolute_path?(path)
        if RUBY_PLATFORM =~ /mingw|msys/
          path =~ %r{^(?:\w:)?[\\/]}
        else
          path.start_with?("/")
        end
      end

      # Return the absolute path for a given target if not a phony target.
      #
      # @param path [String, Symbol, nil]
      #   Given target name.
      #
      # @return [String, Symbol, nil]
      #   Absolute path of given target.
      def absolute_path(path)
        if path.is_a?(String)
          File.expand_path(path)
        else
          path
        end
      end

      # Colorize a builder run message.
      #
      # @param message [String]
      #   Builder run message.
      #
      # @return [Array]
      #   Colorized message with color codes for {Ansi} module.
      def colorize_markup(message)
        if message =~ /^(.*?)(<[^>]+>)(.*)$/
          prefix, code, suffix = $1, $2, $3
          case code
          when "<target>"
            code = :magenta
          when "<source>"
            code = :cyan
          when "<reset>"
            code = :reset
          end
          [prefix, code, *colorize_markup(suffix)].delete_if {|v| v == ""}
        else
          [message]
        end
      end

      # Return a string representation of a command.
      #
      # @param command [Array<String>]
      #   The command.
      #
      # @return [String]
      #   The string representation of the command.
      def command_to_s(command)
        command.map { |c| c[" "] ? "'#{c.gsub("'", "'\\\\''")}'" : c }.join(" ")
      end

      # Determine the number of threads to use by default.
      #
      # @return [Integer]
      #   The number of threads to use by default.
      def determine_n_threads
        # If the user specifies the number of threads in the environment, then
        # respect that.
        if ENV["RSCONS_NTHREADS"] =~ /^(\d+)$/
          return $1.to_i
        end

        # Otherwise try to figure out how many threads are available on the
        # host hardware.
        begin
          case RbConfig::CONFIG["host_os"]
          when /linux/
            return File.read("/proc/cpuinfo").scan(/^processor\s*:/).size
          when /mswin|mingw|msys/
            if `wmic cpu get NumberOfLogicalProcessors -value` =~ /NumberOfLogicalProcessors=(\d+)/
              return $1.to_i
            end
          when /darwin/
            if `sysctl -n hw.ncpu` =~ /(\d+)/
              return $1.to_i
            end
          end
        rescue
        end

        # If we can't figure it out, default to 1.
        1
      end

      # Return a string showing the path specified, or if more than one, then
      # the first path with a "(+D)" afterward, where D is the number of
      # remaining paths.
      #
      # @param paths [Array<String>]
      #   Paths.
      #
      # @return [String]
      #   Condensed path readout.
      def short_format_paths(paths)
        if paths.size == 1
          paths.first
        else
          "#{paths.first} (+#{paths.size - 1})"
        end
      end

      # Look for an executable.
      #
      # @return [String, nil]
      #   Executable path, if found.
      def find_executable(name)
        if name["/"] or name["\\"]
          if File.file?(name) and File.executable?(name)
            return name
          end
        else
          path_entries = ENV["PATH"].split(File::PATH_SEPARATOR)
          path_entries.find do |path_entry|
            if path = test_path_for_executable(path_entry, name)
              return path
            end
          end
        end
      end

      # Format an elapsed time in human-readable format.
      #
      # @return [String]
      #   Elapsed time in human-readable format.
      def format_elapsed_time(elapsed)
        hours = (elapsed / (60 * 60)).to_i
        elapsed -= hours * 60 * 60
        minutes = (elapsed / 60).to_i
        elapsed -= minutes * 60
        seconds = elapsed.ceil
        result = ""
        if hours > 0
          result += "#{hours}h "
        end
        if hours > 0 || minutes > 0
          result += "#{minutes}m "
        end
        result += "#{seconds}s"
        result
      end

      # Return a list of paths matching the specified pattern(s).
      #
      # A pattern can contain a "/**" component to recurse through directories.
      # If the pattern ends with "/**" then only the recursive list of
      # directories will be returned.
      #
      # Examples:
      # - "src/**": return all directories under "src", recursively (including
      #   "src" itself).
      # - "src/**/*": return all files and directories recursively under the src
      #   directory.
      # - "src/**/*.c": return all .c files recursively under the src directory.
      # - "dir/*/": return all directories in dir, but no files.
      #
      # @return [Array<String>] Paths matching the specified pattern(s).
      def glob(*patterns)
        require "pathname"
        patterns.reduce([]) do |result, pattern|
          if pattern.end_with?("/**")
            pattern += "/"
          end
          result += Dir.glob(pattern).map do |path|
            Pathname.new(path.gsub("\\", "/")).cleanpath.to_s
          end
        end.sort
      end

      # Make a relative path corresponding to a possibly absolute one.
      #
      # @param path [String]
      #   Input path that is possibly absolute.
      #
      # @return [String]
      #   Relative path.
      def make_relative_path(path)
        if absolute_path?(path)
          if path =~ %r{^(\w):(.*)$}
            "_#{$1}#{$2}"
          else
            "_#{path}"
          end
        else
          path
        end
      end

      # Parse dependencies from a Makefile or ldc2 dependency file.
      #
      # This method is used internally by Rscons builders.
      #
      # @param mf_fname [String]
      #   File name of the Makefile to read.
      #
      # @return [Array<String>]
      #   Paths of dependency files.
      def parse_dependency_file(mf_fname)
        deps = []
        buildup = ''
        File.read(mf_fname).each_line do |line|
          if line =~ /^(.*)\\\s*$/
            buildup += ' ' + $1
          else
            buildup += ' ' + line
            if buildup =~ /^[^:]+\(\S+\)\s*:.*?:[^:]+\((\S+)\)/
              # ldc2-style dependency line
              deps << $1
            elsif buildup =~ /^.*: (.*)$/
              # Makefile-style dependency line
              mf_deps = $1
              deps += mf_deps.split(' ').map(&:strip)
            end
            buildup = ''
          end
        end
        deps
      end

      # Create or modify a task.
      #
      # @api private
      #
      # @return [Task]
      #   Created task.
      def task(name, options = {}, &block)
        if name == "configure"
          Rscons.application.silent_configure = false
        end
        if task = Task.tasks[name]
          task.modify(options, &block)
        else
          task = Task.new(name, options, &block)
        end
        if name == "configure"
          if configuration_params = Cache.instance["configuration_data"]["params"]
            task.param_values.merge!(configuration_params)
          end
        end
        task
      end

      # Wait for any of a number of threads to complete.
      #
      # @param threads [Array<Thread>]
      #   Threads to wait for.
      #
      # @return [Thread]
      #   The Thread that completed.
      def wait_for_thread(*threads)
        if threads.empty?
          raise "No threads to wait for"
        end
        queue = Queue.new
        threads.each do |thread|
          # Create a wait thread for each thread we're waiting for.
          Thread.new do
            begin
              thread.join
            ensure
              queue.push(thread)
            end
          end
        end
        # Wait for any thread to complete.
        queue.pop
      end

      # Command that can be run to execute this instance of rscons from the
      # current working directory.
      def command_to_execute_me
        command = Pathname.new(File.expand_path($0)).relative_path_from(Dir.pwd).to_s
        command = "./#{command}" unless command["/"]
        command
      end

      private

      # Check if a directory contains a certain executable.
      #
      # @param path_entry [String]
      #   Directory to look in.
      # @param executable [String]
      #   Executable to look for.
      #
      # @return [String, nil]
      #   Executable found.
      def test_path_for_executable(path_entry, executable)
        is_executable = lambda do |path|
          File.file?(path) and File.executable?(path)
        end
        if RbConfig::CONFIG["host_os"] =~ /mswin|windows|mingw|msys/i
          if File.directory?(path_entry)
            executable = executable.downcase
            dir_entries = Dir.entries(path_entry)
            dir_entries.find do |entry|
              path = "#{path_entry}/#{entry}"
              entry = entry.downcase
              if ((entry == executable) or
                  (entry == "#{executable}.exe") or
                  (entry == "#{executable}.com") or
                  (entry == "#{executable}.bat")) and is_executable[path]
                return path
              end
            end
          end
        else
          path = "#{path_entry}/#{executable}"
          return path if is_executable[path]
        end
      end

    end
  end
end
