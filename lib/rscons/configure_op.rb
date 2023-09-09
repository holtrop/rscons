require "fileutils"
require "open3"

module Rscons
  # Class to manage a configure operation.
  class ConfigureOp

    # Create a ConfigureOp.
    #
    # @param script [Script]
    #   Build script.
    def initialize(script)
      @work_dir = "#{Rscons.application.build_dir}/_configure"
      FileUtils.mkdir_p(@work_dir)
      @log_file_name = "#{@work_dir}/config.log"
      @log_fh = File.open(@log_file_name, "wb")
      cache = Cache.instance
      cache["failed_commands"] = []
      cache["configuration_data"] = {}
      unless Rscons.application.silent_configure
        if project_name = script.project_name
          Ansi.write($stdout, "Configuring ", :cyan, project_name, :reset, "...\n")
        else
          $stdout.puts "Configuring project..."
        end
      end
      Task["configure"].params.each do |name, param|
        unless Rscons.application.silent_configure
          Ansi.write($stdout, "Setting #{name}... ", :green, param.value, :reset, "\n")
        end
      end
    end

    # Close the log file handle.
    #
    # @param success [Boolean]
    #   Whether all configure operations were successful.
    #
    # @return [void]
    def close(success)
      @log_fh.close
      @log_fh = nil
      cache = Cache.instance
      cache["configuration_data"]["configured"] = success
      cache["configuration_data"]["params"] = Task["configure"].param_values
      cache.write
    end

    # Check for a working C compiler.
    #
    # @param ccc [Array<String>]
    #   C compiler(s) to check for.
    #
    # @return [void]
    def check_c_compiler(*ccc)
      $stdout.write("Checking for C compiler... ")
      options = {}
      if ccc.last.is_a?(Hash)
        options = ccc.slice!(-1)
      end
      if ccc.empty?
        # Default C compiler search array.
        ccc = %w[gcc clang]
      end
      cc = ccc.find do |cc|
        test_c_compiler(cc, options)
      end
      complete(cc ? 0 : 1, options.merge(
        success_message: cc,
        fail_message: "not found (checked #{ccc.join(", ")})"))
    end

    # Check for a working C++ compiler.
    #
    # @param ccc [Array<String>]
    #   C++ compiler(s) to check for.
    #
    # @return [void]
    def check_cxx_compiler(*ccc)
      $stdout.write("Checking for C++ compiler... ")
      options = {}
      if ccc.last.is_a?(Hash)
        options = ccc.slice!(-1)
      end
      if ccc.empty?
        # Default C++ compiler search array.
        ccc = %w[g++ clang++]
      end
      cc = ccc.find do |cc|
        test_cxx_compiler(cc, options)
      end
      complete(cc ? 0 : 1, options.merge(
        success_message: cc,
        fail_message: "not found (checked #{ccc.join(", ")})"))
    end

    # Check for a working D compiler.
    #
    # @param cdc [Array<String>]
    #   D compiler(s) to check for.
    #
    # @return [void]
    def check_d_compiler(*cdc)
      $stdout.write("Checking for D compiler... ")
      options = {}
      if cdc.last.is_a?(Hash)
        options = cdc.slice!(-1)
      end
      if cdc.empty?
        # Default D compiler search array.
        cdc = %w[gdc ldc2]
      end
      dc = cdc.find do |dc|
        test_d_compiler(dc, options)
      end
      complete(dc ? 0 : 1, options.merge(
        success_message: dc,
        fail_message: "not found (checked #{cdc.join(", ")})"))
    end

    # Check for a package or configure program output.
    def check_cfg(options = {})
      if package = options[:package]
        Ansi.write($stdout, "Checking for package '", :cyan, package, :reset, "'... ")
      elsif program = options[:program]
        Ansi.write($stdout, "Checking '", :cyan, program, :reset, "'... ")
      end
      unless program
        program = "pkg-config"
        unless Util.find_executable(program)
          raise RsconsError.new("Error: executable '#{program}' not found")
        end
      end
      args = options[:args] || %w[--cflags --libs]
      command = [program, *args, package].compact
      stdout, _, status = log_and_test_command(command)
      if status == 0
        store_parse(stdout, options)
      end
      complete(status, options)
    end

    # Check for a C header.
    def check_c_header(header_name, options = {})
      check_cpppath = [nil] + (options[:check_cpppath] || [])
      Ansi.write($stdout, "Checking for C header '", :cyan, header_name, :reset, "'... ")
      File.open("#{@work_dir}/cfgtest.c", "wb") do |fh|
        fh.puts <<-EOF
          #include "#{header_name}"
          int main(int argc, char * argv[]) {
            return 0;
          }
        EOF
      end
      vars = {
        "LD" => "${CC}",
        "_SOURCES" => "#{@work_dir}/cfgtest.c",
        "_TARGET" => "#{@work_dir}/cfgtest.o",
        "_DEPFILE" => "#{@work_dir}/cfgtest.mf",
      }
      status = 1
      check_cpppath.each do |cpppath|
        env = BasicEnvironment.new
        if cpppath
          env["CPPPATH"] += Array(cpppath)
        end
        command = env.build_command("${CCCMD}", vars)
        _, _, status = log_and_test_command(command)
        if status == 0
          if cpppath
            store_append({"CPPPATH" => Array(cpppath)}, options)
          end
          break
        end
      end
      complete(status, options)
    end

    # Check for a C++ header.
    def check_cxx_header(header_name, options = {})
      check_cpppath = [nil] + (options[:check_cpppath] || [])
      Ansi.write($stdout, "Checking for C++ header '", :cyan, header_name, :reset, "'... ")
      File.open("#{@work_dir}/cfgtest.cxx", "wb") do |fh|
        fh.puts <<-EOF
          #include "#{header_name}"
          int main(int argc, char * argv[]) {
            return 0;
          }
        EOF
      end
      vars = {
        "LD" => "${CXX}",
        "_SOURCES" => "#{@work_dir}/cfgtest.cxx",
        "_TARGET" => "#{@work_dir}/cfgtest.o",
        "_DEPFILE" => "#{@work_dir}/cfgtest.mf",
      }
      status = 1
      check_cpppath.each do |cpppath|
        env = BasicEnvironment.new
        if cpppath
          env["CPPPATH"] += Array(cpppath)
        end
        command = env.build_command("${CXXCMD}", vars)
        _, _, status = log_and_test_command(command)
        if status == 0
          if cpppath
            store_append({"CPPPATH" => Array(cpppath)}, options)
          end
          break
        end
      end
      complete(status, options)
    end

    # Check for a D import.
    def check_d_import(d_import, options = {})
      check_d_import_path = [nil] + (options[:check_d_import_path] || [])
      Ansi.write($stdout, "Checking for D import '", :cyan, d_import, :reset, "'... ")
      File.open("#{@work_dir}/cfgtest.d", "wb") do |fh|
        fh.puts <<-EOF
          import #{d_import};
          int main() {
            return 0;
          }
        EOF
      end
      vars = {
        "LD" => "${DC}",
        "_SOURCES" => "#{@work_dir}/cfgtest.d",
        "_TARGET" => "#{@work_dir}/cfgtest.o",
        "_DEPFILE" => "#{@work_dir}/cfgtest.mf",
      }
      status = 1
      check_d_import_path.each do |d_import_path|
        env = BasicEnvironment.new
        if d_import_path
          env["D_IMPORT_PATH"] += Array(d_import_path)
        end
        command = env.build_command("${DCCMD}", vars)
        _, _, status = log_and_test_command(command)
        if status == 0
          if d_import_path
            store_append({"D_IMPORT_PATH" => Array(d_import_path)}, options)
          end
          break
        end
      end
      complete(status, options)
    end

    # Check for a library.
    def check_lib(lib, options = {})
      check_libpath = [nil] + (options[:check_libpath] || [])
      Ansi.write($stdout, "Checking for library '", :cyan, lib, :reset, "'... ")
      File.open("#{@work_dir}/cfgtest.c", "wb") do |fh|
        fh.puts <<-EOF
          int main(int argc, char * argv[]) {
            return 0;
          }
        EOF
      end
      vars = {
        "LD" => "${CC}",
        "LIBS" => [lib],
        "_SOURCES" => "#{@work_dir}/cfgtest.c",
        "_TARGET" => "#{@work_dir}/cfgtest.exe",
      }
      status = 1
      check_libpath.each do |libpath|
        env = BasicEnvironment.new
        if libpath
          env["LIBPATH"] += Array(libpath)
        end
        command = env.build_command("${LDCMD}", vars)
        _, _, status = log_and_test_command(command)
        if status == 0
          if libpath
            store_append({"LIBPATH" => Array(libpath)}, options)
          end
          break
        end
      end
      if status == 0
        store_append({"LIBS" => [lib]}, options)
      end
      complete(status, options)
    end

    # Check for a executable program.
    def check_program(program, options = {})
      Ansi.write($stdout, "Checking for program '", :cyan, program, :reset, "'... ")
      path = Util.find_executable(program)
      complete(path ? 0 : 1, options.merge(success_message: path))
    end

    # Execute a test command and log the result.
    #
    # @param command [Array<String>]
    #   Command to execute.
    # @param options [Hash]
    #   Optional arguments.
    # @option options [String] :stdin
    #   Data to send to standard input stream of the executed command.
    #
    # @return [String, String, Process::Status]
    #   stdout, stderr, status
    def log_and_test_command(command, options = {})
      begin
        @log_fh.puts("Command: #{command.join(" ")}")
        stdout, stderr, status = Open3.capture3(*command, stdin_data: options[:stdin])
        @log_fh.puts("Exit status: #{status.to_i}")
        @log_fh.write(stdout)
        @log_fh.write(stderr)
        [stdout, stderr, status]
      rescue Errno::ENOENT
        ["", "", 127]
      end
    end

    # Store construction variables for merging into the Cache.
    #
    # @param vars [Hash]
    #   Hash containing the variables to merge.
    # @param options [Hash]
    #   Options.
    # @option options [String] :use
    #   A 'use' name. If specified, the construction variables are only applied
    #   to an Environment if the Environment is constructed with a matching
    #   `:use` value.
    def store_merge(vars, options = {})
      store_vars = store_common(options)
      store_vars["merge"] ||= {}
      vars.each_pair do |key, value|
        store_vars["merge"][key] = value
      end
    end

    # Store construction variables for appending into the Cache.
    #
    # @param vars [Hash]
    #   Hash containing the variables to append.
    # @param options [Hash]
    #   Options.
    # @option options [String] :use
    #   A 'use' name. If specified, the construction variables are only applied
    #   to an Environment if the Environment is constructed with a matching
    #   `:use` value.
    def store_append(vars, options = {})
      store_vars = store_common(options)
      store_vars["append"] ||= {}
      vars.each_pair do |key, value|
        if store_vars["append"][key].is_a?(Array) and value.is_a?(Array)
          store_vars["append"][key] += value
        else
          store_vars["append"][key] = value
        end
      end
    end

    # Store flags to be parsed into the Cache.
    #
    # @param flags [String]
    #   String containing the flags to parse.
    # @param options [Hash]
    #   Options.
    # @option options [String] :use
    #   A 'use' name. If specified, the construction variables are only applied
    #   to an Environment if the Environment is constructed with a matching
    #   `:use` value.
    def store_parse(flags, options = {})
      store_vars = store_common(options)
      store_vars["parse"] ||= []
      store_vars["parse"] << flags
    end

    # Perform processing common to several configure checks.
    #
    # @param status [Process::Status, Integer]
    #   Process exit code. 0 for success, non-zero for error.
    # @param options [Hash]
    #   Common check options.
    # @option options [Boolean] :fail
    #   Whether to fail configuration if the requested item is not found.
    #   This defaults to true if the :set_define option is not specified,
    #   otherwise defaults to false if :set_define option is specified.
    # @option options [String] :set_define
    #   A define to set (in CPPDEFINES) if the requested item is found.
    # @option options [String] :success_message
    #   Message to print on success (default "found").
    # @option options [String] :fail_message
    #   Message to print on failure (default "not found").
    def complete(status, options)
      success_message = options[:success_message] || "found"
      fail_message = options[:fail_message] || "not found"
      if status == 0
        Ansi.write($stdout, :green, "#{success_message}\n")
        if options[:set_define]
          store_append("CPPDEFINES" => [options[:set_define]])
        end
      else
        should_fail =
          if options.has_key?(:fail)
            options[:fail]
          else
            !options[:set_define]
          end
        color = should_fail ? :red : :yellow
        Ansi.write($stdout, color, "#{fail_message}\n")
        if options[:on_fail].is_a?(String)
          $stdout.puts(options[:on_fail])
        elsif options[:on_fail].is_a?(Proc)
          options[:on_fail].call
        end
        if should_fail
          raise RsconsError.new("Configuration failed; log file written to #{@log_file_name}")
        end
      end
    end

    private

    # Test a C compiler.
    #
    # @param cc [String]
    #   C compiler to test.
    #
    # @return [Boolean]
    #   Whether the C compiler tested successfully.
    def test_c_compiler(cc, options)
      File.open("#{@work_dir}/cfgtest.c", "wb") do |fh|
        fh.puts <<-EOF
          int fun(int val) {
            return val * 2;
          }
        EOF
      end
      command = %W[#{cc} -c -o #{@work_dir}/cfgtest.o #{@work_dir}/cfgtest.c]
      merge = {"CC" => cc}
      _, _, status = log_and_test_command(command)
      if status == 0
        store_merge(merge, options)
        true
      end
    end

    # Test a C++ compiler.
    #
    # @param cc [String]
    #   C++ compiler to test.
    #
    # @return [Boolean]
    #   Whether the C++ compiler tested successfully.
    def test_cxx_compiler(cc, options)
      File.open("#{@work_dir}/cfgtest.cxx", "wb") do |fh|
        fh.puts <<-EOF
          template<typename T>
          T fun(T val) {
            return val * 2;
          }
        EOF
      end
      command = %W[#{cc} -c -o #{@work_dir}/cfgtest.o #{@work_dir}/cfgtest.cxx]
      merge = {"CXX" => cc}
      _, _, status = log_and_test_command(command)
      if status == 0
        store_merge(merge, options)
        true
      end
    end

    # Test a D compiler.
    #
    # @param dc [String]
    #   D compiler to test.
    #
    # @return [Boolean]
    #   Whether the D compiler tested successfully.
    def test_d_compiler(dc, options)
      File.open("#{@work_dir}/cfgtest.d", "wb") do |fh|
        fh.puts <<-EOF
          import core.math;
          int fun() {
            return 0;
          }
        EOF
      end
      [:gdc, :ldc2].find do |dc_test|
        case dc_test
        when :gdc
          command = %W[#{dc} -c -o #{@work_dir}/cfgtest.o #{@work_dir}/cfgtest.d]
          merge = {"DC" => dc}
        when :ldc2
          # ldc2 on Windows expect an object file suffix of .obj.
          ldc_objsuffix = RUBY_PLATFORM =~ /mingw|msys/ ? ".obj" : ".o"
          command = %W[#{dc} -c -of #{@work_dir}/cfgtest#{ldc_objsuffix} #{@work_dir}/cfgtest.d]
          env = BasicEnvironment.new
          merge = {
            "DC" => dc,
            "DCCMD" => env["DCCMD"].map {|e| e.sub(/^-o$/, "-of")},
            "LDCMD" => env["LDCMD"].map {|e| e.sub(/^-o$/, "-of")},
            "DDEPGEN" => ["-deps=${_DEPFILE}"],
          }
          merge["OBJSUFFIX"] = [ldc_objsuffix]
        end
        _, _, status = log_and_test_command(command)
        if status == 0
          store_merge(merge, options)
          true
        end
      end
    end

    # Common functionality for all store methods.
    #
    # @param options [Hash]
    #   Options.
    #
    # @return [Hash]
    #   Configuration Hash for storing vars.
    def store_common(options)
      if options[:use] == false
        {}
      else
        usename =
          if options[:use]
            options[:use].to_s
          else
            "_default_"
          end
        cache = Cache.instance
        cache["configuration_data"]["vars"] ||= {}
        cache["configuration_data"]["vars"][usename] ||= {}
      end
    end

  end
end
